// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    func switchFromEmptyWorkspaceAfterClose(_ workspaceId: WorkspaceDescriptor.ID) {
        guard let controller, controller.hasStartedServices,
              let monitorId = controller.workspaceManager.monitorId(for: workspaceId),
              controller.workspaceManager.activeWorkspace(on: monitorId)?.id == workspaceId,
              controller.workspaceManager.entries(in: workspaceId).isEmpty,
              let target = controller.workspaceManager.nextWorkspaceInOrder(
                  on: monitorId, from: workspaceId, wrapAround: true, skipEmpty: true
              )
        else { return }
        invalidateActivationObservations()
        controller.workspaceNavigationHandler.switchWorkspace(
            rawWorkspaceID: target.name, affectedWorkspaces: [workspaceId]
        )
    }
}
