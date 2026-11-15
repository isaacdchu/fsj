//
//  FSJApp.swift
//  FSJ
//
//  Created by Isaac Chu on 11/14/26.
//

import SwiftUI

@main
struct FSJApp: App {
    @State private var model = AppModel.live()
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .light

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
