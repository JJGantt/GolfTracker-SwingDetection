import SwiftUI

// MARK: - Club Selector
//
// The club picker over the map: crown-driven with expanding labels on
// watchOS 11+, and an inline up/down stack in the button column on watchOS 10.
extension ActiveRoundView {
    @ViewBuilder
    func clubSelectorOverlay(clubFontSize: CGFloat) -> some View {
        // On watchOS 10, club selector is integrated into buttonsOverlay instead
        if #available(watchOS 11.0, *) {
            if clubs.isEmpty {
                Text("No Clubs")
                    .font(.system(size: clubFontSize, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                clubSelectorOverlayModern(clubFontSize: clubFontSize)
            }
        }
        // watchOS 10: club selector is shown in buttonsOverlay via legacyClubSelector()
    }

    // MARK: - watchOS 11+ Club Selector (crown-based with expanding clubs)
    @available(watchOS 11.0, *)
    @ViewBuilder
    func clubSelectorOverlayModern(clubFontSize: CGFloat) -> some View {
        let currentIndex = Int(selectedClubIndex.rounded()) % clubs.count
        let previous2Index = (currentIndex - 2 + clubs.count) % clubs.count
        let previous1Index = (currentIndex - 1 + clubs.count) % clubs.count
        let next1Index = (currentIndex + 1) % clubs.count
        let next2Index = (currentIndex + 2) % clubs.count

        let previous2Club = clubs[previous2Index]
        let previous1Club = clubs[previous1Index]
        let next1Club = clubs[next1Index]
        let next2Club = clubs[next2Index]

        let currentSize = isCrownScrolling ? clubFontSize * 1.3 : clubFontSize
        let adjacent1Size = clubFontSize * 0.8
        let adjacent2Size = clubFontSize * 0.65

        let adjacent1Height: CGFloat = adjacent1Size + 8
        let adjacent2Height: CGFloat = adjacent2Size + 4

        VStack {
            Spacer()
                .frame(height: crownOffset)
            HStack {
                Spacer()

                ZStack {
                    Text(selectedClub.map { store.getTypeName(for: $0) } ?? "No Club")
                        .font(.system(size: currentSize, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.ultraThinMaterial)
                                .opacity(0.9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    if isCrownScrolling {
                        if currentIndex >= 1 {
                            Text(store.getTypeName(for: previous1Club))
                                .font(.system(size: adjacent1Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .offset(y: -adjacent1Height)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if currentIndex >= 2 {
                            Text(store.getTypeName(for: previous2Club))
                                .font(.system(size: adjacent2Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.45)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                                .offset(y: -(adjacent1Height + adjacent2Height))
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    if isCrownScrolling {
                        if currentIndex < clubs.count - 1 {
                            Text(store.getTypeName(for: next1Club))
                                .font(.system(size: adjacent1Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .offset(y: adjacent1Height)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if currentIndex < clubs.count - 2 {
                            Text(store.getTypeName(for: next2Club))
                                .font(.system(size: adjacent2Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.45)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                                .offset(y: adjacent1Height + adjacent2Height)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .padding(.trailing, 8)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: isCrownScrolling)
        .opacity(isPlacingTarget ? 0 : 1)
    }

    // MARK: - watchOS 10 Club Selector (inline in button stack)
    @ViewBuilder
    func legacyClubSelector(buttonSize: CGFloat) -> some View {
        let currentIndex = Int(selectedClubIndex.rounded()) % clubs.count
        let iconSize: CGFloat = buttonSize * 0.45

        VStack(spacing: 4) {
            // Up arrow button - previous club
            Button(action: {
                if currentIndex > 0 {
                    selectedClubIndex = Double(currentIndex - 1)
                    WKInterfaceDevice.current().play(.click)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.9)
                        .frame(width: buttonSize, height: buttonSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    Image(systemName: "chevron.up")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(currentIndex > 0 ? .white : .white.opacity(0.3))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(currentIndex <= 0)

            // Current club name - tap to re-enable auto-selection
            Text(selectedClub.map { store.getTypeName(for: $0) } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(manualClubOverride ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.blue.opacity(0.7)))
                        .opacity(0.9)
                )
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                .onTapGesture {
                    if manualClubOverride {
                        manualClubOverride = false
                        WKInterfaceDevice.current().play(.click)
                    }
                }

            // Down arrow button - next club
            Button(action: {
                if currentIndex < clubs.count - 1 {
                    selectedClubIndex = Double(currentIndex + 1)
                    WKInterfaceDevice.current().play(.click)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.9)
                        .frame(width: buttonSize, height: buttonSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(currentIndex < clubs.count - 1 ? .white : .white.opacity(0.3))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(currentIndex >= clubs.count - 1)
        }
    }
}
