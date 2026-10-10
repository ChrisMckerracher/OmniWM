// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    struct ProvisionalActivationSource {
        let token: WindowToken
        let generation: UInt64
        let targetPID: pid_t
    }

    var provisionalActivationSourceToken: WindowToken? {
        guard let source = provisionalActivationSource,
              isActivationObservationGenerationCurrent(source.generation) else { return nil }
        return source.token
    }

    func clearProvisionalActivationSource(matching generation: UInt64) {
        if provisionalActivationSource?.generation == generation { provisionalActivationSource = nil }
    }

    func isCurrentFocusedAdmissionContinuation(
        _ continuation: FocusedAdmissionRetryContinuation
    ) -> Bool {
        guard isActivationObservationGenerationCurrent(continuation.observationGeneration) else {
            return false
        }
        guard let callbackGeneration = continuation.callbackGeneration else { return true }
        return AppAXContextRegistry.contexts[continuation.token.pid]?.callbackGeneration == callbackGeneration
    }

    func departingWorkspace(for pid: pid_t, controller: WMController) -> WorkspaceDescriptor.ID? {
        let token = controller.workspaceManager.nativeManagedFocusToken
            ?? controller.workspaceManager.externalFocusToken ?? provisionalActivationSourceToken
        return token.flatMap { $0.pid == pid ? controller.workspaceManager.entry(for: $0)?.workspaceId : nil }
    }
}
