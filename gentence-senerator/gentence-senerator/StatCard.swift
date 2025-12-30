//
//  StatCard.swift
//  gentence-senerator
//
//  Created by Simon Chervenak on 12/30/25.
//
import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
            }
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundColor(color)
        }
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(10)
    }
}
