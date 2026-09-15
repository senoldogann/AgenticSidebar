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
    private let identifier = EventHotKeyID(signature: 0x41534252, id: 1) // ASBR
    private let action: @MainActor () -> Void
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(action: @escaping @MainActor () -> Void) {
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

                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    guard receivedIdentifier.signature == controller.identifier.signature,
                          receivedIdentifier.id == controller.identifier.id else {
                        return OSStatus(eventNotHandledErr)
                    }

                    controller.action()
                    return noErr
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
