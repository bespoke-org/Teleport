//
//  ContentView.swift
//  teleport
//
//  Created by Michael Chernigin on 21.04.2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Teleport")
                .font(.title2.bold())
            Text("This app runs from the menu bar. Open Settings to add portals, and use the menu bar to connect.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360)
    }
}

#Preview {
    ContentView()
}
