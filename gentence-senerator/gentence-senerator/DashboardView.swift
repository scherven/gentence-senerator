//
//  DashboardView.swift
//  gentence-senerator
//
//  Created by Simon Chervenak on 12/30/25.
//
import SwiftUI

struct DashboardView: View {
    @Binding var selectedLanguage: String
    @State private var navigateToPractice = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Spacer()
                
                // Welcome section
                VStack(spacing: 10) {
                    Text("Welcome!")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Learning \(selectedLanguage)")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                // Stats cards
                VStack(spacing: 15) {
                    StatCard(title: "Sentences Practiced", value: "0", color: .blue)
                    StatCard(title: "Current Streak", value: "0 days", color: .green)
                    StatCard(title: "Accuracy", value: "0%", color: .orange)
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Practice button
                NavigationLink(destination: PracticeView(selectedLanguage: $selectedLanguage), isActive: $navigateToPractice) {
                    EmptyView()
                }
                
                Button(action: {
                    navigateToPractice = true
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Practice")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(15)
                }
                .padding(.horizontal, 40)
                
                Spacer()
            }
        }
    }
}
