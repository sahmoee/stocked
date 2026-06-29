// ProfileAvatar.swift — shared chef avatar (Build 295).
//
// Renders the user's chef avatar as either a user-supplied photo (cookingProfile.avatarPhotoData)
// or, when no photo is set, the chosen chef emoji (cookingProfile.avatarEmoji). The editable
// variant lets the user tap to switch the chef emoji skin tone or attach their own photo.
//
// Used by the drawer chef row and the Edit Profile screen so avatar handling lives in one place.

import SwiftUI
import PhotosUI

// MARK: - Read-only avatar (photo or emoji)
struct ProfileAvatarView: View {
    var size: CGFloat = 46
    @Environment(AppSession.self) private var session

    private var photo: UIImage? {
        guard let data = session.guestStore.cookingProfile.avatarPhotoData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(session.guestStore.cookingProfile.avatarEmoji)
                    .font(.system(size: size * 0.62))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Editable avatar (tap to change skin tone or add a photo)
struct EditableProfileAvatar: View {
    var size: CGFloat = 96
    @Environment(AppSession.self) private var session

    @State private var showOptions = false
    @State private var showSkinTones = false
    @State private var photoItem: PhotosPickerItem? = nil

    // Same chef-emoji matrix used by onboarding: three styles, six skin tones each.
    private let chefGrid: [[String]] = [
        ["👨‍🍳","👨🏻‍🍳","👨🏼‍🍳","👨🏽‍🍳","👨🏾‍🍳","👨🏿‍🍳"],
        ["👩‍🍳","👩🏻‍🍳","👩🏼‍🍳","👩🏽‍🍳","👩🏾‍🍳","👩🏿‍🍳"],
        ["🧑‍🍳","🧑🏻‍🍳","🧑🏼‍🍳","🧑🏽‍🍳","🧑🏾‍🍳","🧑🏿‍🍳"],
    ]

    private var hasPhoto: Bool { session.guestStore.cookingProfile.avatarPhotoData != nil }

    var body: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.25)) { showOptions.toggle() }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProfileAvatarView(size: size)
                    // Small edit affordance.
                    ZStack {
                        Circle().fill(Color.stockedGold).frame(width: size * 0.30, height: size * 0.30)
                        Image(systemName: "pencil")
                            .font(.system(size: size * 0.15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }.buttonStyle(.plain)

            if showOptions {
                VStack(spacing: 10) {
                    // Choice 1: switch chef emoji skin tone.
                    Button {
                        withAnimation(.spring(response: 0.2)) { showSkinTones.toggle() }
                    } label: {
                        optionRow(icon: "face.smiling", title: "Choose Chef Icon")
                    }.buttonStyle(.plain)

                    if showSkinTones {
                        VStack(spacing: 6) {
                            ForEach(chefGrid, id: \.self) { row in
                                HStack(spacing: 6) {
                                    ForEach(row, id: \.self) { e in
                                        Button {
                                            withAnimation(.spring(response: 0.2)) {
                                                var p = session.guestStore.cookingProfile
                                                p.avatarEmoji = e
                                                p.avatarPhotoData = nil   // emoji choice clears any photo
                                                session.guestStore.cookingProfile = p
                                                showSkinTones = false
                                                showOptions = false
                                            }
                                        } label: {
                                            Text(e).font(.system(size: 28))
                                                .padding(5)
                                                .background(!hasPhoto && session.guestStore.cookingProfile.avatarEmoji == e
                                                            ? Color.stockedGold.opacity(0.2) : Color.clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }

                    // Choice 2: add / replace your own photo.
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        optionRow(icon: "photo.on.rectangle", title: hasPhoto ? "Replace Photo" : "Add Your Own Photo")
                    }

                    // Remove photo (only when one is set), reverting to the chef emoji.
                    if hasPhoto {
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                session.guestStore.cookingProfile.avatarPhotoData = nil
                                showOptions = false
                            }
                        } label: {
                            optionRow(icon: "trash", title: "Remove Photo", tint: .red)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 280)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let jpeg = img.downscaledJPEG(maxDimension: 512, quality: 0.8) {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.2)) {
                            session.guestStore.cookingProfile.avatarPhotoData = jpeg
                            showOptions = false
                            showSkinTones = false
                        }
                    }
                }
                await MainActor.run { photoItem = nil }
            }
        }
    }

    private func optionRow(icon: String, title: String, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint == .primary ? Color.stockedGold : tint)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(tint == .primary ? session.themeTextColor : tint)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Image downscaling helper (avoids storing huge photos in the profile)
private extension UIImage {
    func downscaledJPEG(maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
