import Carbon
import Foundation

protocol GlobalHotKeyRegistering {
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws
    func unregister()
}

enum GlobalHotKeyError: Error, Equatable {
    case registrationFailed(OSStatus)
}

final class GlobalHotKey: GlobalHotKeyRegistering, @unchecked Sendable {
    private let hotKeyID = EventHotKeyID(signature: OSType(0x53484F54), id: 1)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    deinit {
        unregister()
    }

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) throws {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            self.handler = nil
            throw GlobalHotKeyError.registrationFailed(installStatus)
        }

        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            unregister()
            throw GlobalHotKeyError.registrationFailed(registrationStatus)
        }
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

        handler = nil
    }

    fileprivate func handle(event: EventRef?) {
        guard let event else { return }

        var receivedHotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedHotKeyID
        )

        guard parameterStatus == noErr,
              receivedHotKeyID.signature == hotKeyID.signature,
              receivedHotKeyID.id == hotKeyID.id else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handler?()
        }
    }
}

private let globalHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return noErr }

    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    hotKey.handle(event: event)
    return noErr
}
