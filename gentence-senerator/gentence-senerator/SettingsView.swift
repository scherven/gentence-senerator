//
//  SettingsView.swift
//  gentence-senerator
//
//  Created by Simon Chervenak on 12/30/25.
//
import SwiftUI

struct SettingsView: View {
    @Binding var selectedLanguage: String
    
    let languages = ["Mandarin", "French", "German", "Spanish", "Italian", "Portuguese", "Japanese", "Korean"]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Target Language")) {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(languages, id: \.self) { language in
                            Text(language).tag(language)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("Current Language")
                        Spacer()
                        Text(selectedLanguage)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
