// The synthetic screen the offscreen render tools draw over (never a capture of the real screen):
// a 14-inch MacBook Pro desktop with a light "Backup" window, a dark terminal, menu bar, notch
// and dock, plus the targets the shots point at. Used by tools/overlay-render.
import AppKit
import BenjiCore
import SwiftUI

let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)          // 14-inch MacBook Pro, in points
let menuBar: CGFloat = 33
let dock: CGFloat = 64
let visible = CGRect(x: 0, y: dock, width: 1512, height: 982 - menuBar - dock)
let notch = CGRect(x: 661, y: 982 - 32, width: 190, height: 32)
let panel = CGRect(x: 556, y: 982 - 32 - 150, width: 400, height: 150)   // Benji's open notch panel

/// Top-left coordinates (as drawn) to AppKit global.
func g(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: screen.height - y) }
func g(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: screen.height - r.maxY, width: r.width, height: r.height) }

// MARK: the synthetic screen

struct Desktop: View {
    var dark = false
    var showPanel = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.74), Color(red: 0.78, green: 0.62, blue: 0.70)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if dark { DarkApp().offset(x: 700, y: 360) } else { LightApp().offset(x: 150, y: 90) }
            // Menu bar with the notch.
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("Photos").bold(); Text("File"); Text("Edit"); Text("View")
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75"); Text("Sat 31 Oct  09:41")
            }
            .font(.system(size: 13)).foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(width: screen.width, height: menuBar)
            .background(.black.opacity(0.25))
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(.black).frame(width: notch.width, height: notch.height).offset(x: notch.minX)
            if showPanel {
                RoundedRectangle(cornerRadius: 22).fill(.black)
                    .frame(width: panel.width, height: panel.height + 32)
                    .overlay(alignment: .bottomLeading) {
                        Text("Tick Sync files, then Include photos, then press Save.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).padding(18)
                    }
                    .offset(x: panel.minX)
            }
            // Dock.
            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.35))
                .frame(width: 560, height: 56)
                .overlay { HStack(spacing: 14) { ForEach(0..<9) { i in
                    RoundedRectangle(cornerRadius: 10).fill(Color(hue: Double(i) / 9, saturation: 0.6, brightness: 0.9))
                        .frame(width: 40, height: 40) } } }
                .offset(x: (screen.width - 560) / 2, y: screen.height - 60)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }
}

/// A light-appearance window. Positions below are this window's, offset by (150, 90).
struct LightApp: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer()
                Text("Library").font(.system(size: 13, weight: .semibold))
                Spacer()
                Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
            }
            .padding(.horizontal, 14).frame(height: 44).background(Color(white: 0.94))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["Recents", "Favourites", "Albums", "Shared", "Trash"], id: \.self) {
                        Label($0, systemImage: "folder").font(.system(size: 13))
                    }
                }
                .padding(16).frame(width: 180, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                .background(Color(white: 0.9))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Backup").font(.system(size: 20, weight: .bold))
                    check("Sync files", on: true)
                    check("Include photos", on: false)
                    check("Include videos", on: false)
                    HStack {
                        Text("Customer name").font(.system(size: 13))
                        RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.5))
                            .frame(width: 220, height: 24)
                            .overlay(alignment: .leading) { Text("Rahim Traders").font(.system(size: 13)).padding(.leading, 6) }
                    }
                    PhotoGrid().frame(width: 420, height: 190)
                    HStack { Spacer()
                        Text("Save").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                    }.frame(width: 420)
                }
                .padding(24)
                Spacer()
            }
        }
        .frame(width: 900, height: 560)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .compositingGroup()
        .shadow(radius: 20)
        .environment(\.colorScheme, .light)
    }

    func check(_ title: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : .white)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.6)))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                .frame(width: 16, height: 16)
            Text(title).font(.system(size: 13))
        }
    }
}

/// Busy content: a grid of colourful "photos".
struct PhotoGrid: View {
    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(64), spacing: 6), count: 6)
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(0..<18) { i in
                LinearGradient(colors: [Color(hue: Double(i * 7 % 18) / 18, saturation: 0.7, brightness: 0.95),
                                        Color(hue: Double(i * 5 % 18) / 18, saturation: 0.9, brightness: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Circle().fill(.white.opacity(0.5)).frame(width: 18).offset(x: CGFloat(i % 3) * 9 - 9, y: -8) }
                    .frame(width: 64, height: 58).clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// A dark-appearance window running into the display's bottom-right corner, at (700, 360).
struct DarkApp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                Spacer(); Text("Terminal — zsh").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8)); Spacer()
            }.padding(.horizontal, 14).frame(height: 36).background(Color(white: 0.17))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<14) { i in
                    Text("~/Workspace % swift build   [\(i)/37] Compiling BenjiCore OverlayMotion.swift")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.85))
                }
            }.padding(14)
            Spacer()
            HStack { Spacer()
                Text("Run").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.7)))
            }.padding(.trailing, 14).padding(.bottom, 82)
        }
        .frame(width: 812, height: 622)
        .background(Color(white: 0.1))
    }
}

// Targets on the synthetic screen (drawn coordinates, top-left origin). The light window is at
// (150, 90): 44 pt toolbar, 180 pt sidebar, 24 pt padding, 27 pt title, 14 pt row spacing.
let contentX: CGFloat = 150 + 180 + 24
let firstRowY: CGFloat = 90 + 44 + 24 + 27 + 14 + 8
let gridTop: CGFloat = firstRowY - 8 + 3 * 30 + 38
let share = g(150 + 900 - 14 - 34, 90 + 22)
let syncFiles = g(contentX + 8, firstRowY)
let includePhotos = g(contentX + 8, firstRowY + 30)
let photoGrid = g(CGRect(x: contentX, y: gridTop, width: 420, height: 190))
let saveButton = g(contentX + 420 - 30, gridTop + 190 + 14 + 13)
let run = g(1512 - 36, 982 - 95)
let wifi = g(1323, 16)

