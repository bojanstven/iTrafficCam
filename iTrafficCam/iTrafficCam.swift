//
//  iTrafficCam.swift
//  iTrafficCam
//
//  Created by Bojan Mijic on 2/9/26.
//

import SwiftUI

@main
struct iTrafficCam: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video File") {
                    NotificationCenter.default.post(name: Notification.Name("OpenVideoFile"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
