//
//  BatchSelectionModel.swift
//  GestaltKitTool
//
//  Reusable selection state for multi-select batch operations.
//

import Combine
import SwiftUI

/// Observable selection model for batch operations.
/// Tracks multi-select mode and the set of selected item paths.
@MainActor
final class BatchSelectionModel: ObservableObject {
    @Published var isMultiSelectMode = false
    @Published var selectedPaths: Set<String> = []

    /// Toggle selection for a specific path.
    func toggle(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    /// Check if a path is currently selected.
    func contains(_ path: String) -> Bool {
        selectedPaths.contains(path)
    }

    /// Enter multi-select mode and select the given path.
    func enterMultiSelect(selecting path: String? = nil) {
        isMultiSelectMode = true
        if let path {
            selectedPaths.insert(path)
        }
    }

    /// Exit multi-select mode and clear all selections.
    func exitMultiSelect() {
        isMultiSelectMode = false
        selectedPaths.removeAll()
    }

    /// Clear all selected paths without exiting multi-select mode.
    func clearSelection() {
        selectedPaths.removeAll()
    }

    /// The number of currently selected items.
    var count: Int { selectedPaths.count }

    /// Whether any items are currently selected.
    var hasSelection: Bool { !selectedPaths.isEmpty }
}
