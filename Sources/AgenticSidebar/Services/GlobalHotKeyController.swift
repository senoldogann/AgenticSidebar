import Carbon.HIToolbox

struct GlobalHotKeyRegistrationError: Error, Equatable {
    enum Stage: Equatable {
        case installEventHandler
        case registerHotKey
    }

    let stage: Stage
    let status: OSStatus
}

@MainActor
final class GlobalHotKeyController {
    private let identifier: EventHotKeyID
    private let action: @MainActor () -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// - Parameter hotKeyID: Aynı imzadaki (ASBR) ek kayıtlar için farklı
    ///   kimlik (ör. 1: göster/gizle, 2: snap). Varsayılan tekil davranışı korur.
    init(action: @escaping @MainActor () -> Void, hotKeyID: UInt32 = 1) {
        self.identifier = EventHotKeyID(signature: 0x41534252, id: hotKeyID)
        self.action = action
    }

    func register(_ shortcut: GlobalShortcutSpec = .default) throws {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var receivedIdentifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedIdentifier
                )

                guard parameterStatus == noErr else {
                    return parameterStatus
                }

                // `self` is owned by the app delegate for the whole process
                // lifetime, so an unretained reference cannot dangle here.
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                // The handler is installed on the application event target and
                // runs on the main thread in practice. Hop explicitly instead of
                // trapping with assumeIsolated if that ever changes.
                guard Thread.isMainThread else {
                    DispatchQueue.main.async {
                        _ = MainActor.assumeIsolated {
                            controller.handle(receivedIdentifier)
                        }
                    }
                    return noErr
                }

                return MainActor.assumeIsolated {
                    controller.handle(receivedIdentifier)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )

        guard handlerStatus == noErr else {
            throw GlobalHotKeyRegistrationError(
                stage: .installEventHandler,
                status: handlerStatus
            )
        }

        eventHandlerRef = installedHandler

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registrationStatus == noErr else {
            unregister()
            throw GlobalHotKeyRegistrationError(
                stage: .registerHotKey,
                status: registrationStatus
            )
        }

        hotKeyRef = registeredHotKey
    }

    func handle(_ receivedIdentifier: EventHotKeyID) -> OSStatus {
        guard receivedIdentifier.signature == identifier.signature,
              receivedIdentifier.id == identifier.id else {
            return OSStatus(eventNotHandledErr)
        }

        action()
        return noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    isolated deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
