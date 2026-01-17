import SwiftUI
import CoreLocation

// Helper struct to pass camera information to satellite view
struct MapCameraInfo {
    let centerCoordinate: CLLocationCoordinate2D
    let bearing: Double
    let distance: Double
}

struct SatelliteImageView: View {
    let courseId: UUID
    let holeNumber: Int
    let userLocation: CLLocation?
    let hole: Hole
    let strokes: [Stroke]
    let targets: [Target]
    let lastRealStroke: Stroke?
    let temporaryPenaltyPosition: CLLocationCoordinate2D?
    let heading: Double?
    let mapCamera: MapCameraInfo
    let isPlacingTarget: Bool
    let isPlacingPenalty: Bool
    let onTap: ((CLLocationCoordinate2D) -> Void)?

    @State private var scale: CGFloat = 1.0
    @StateObject private var cacheManager = WatchSatelliteCacheManager.shared
    @FocusState private var isFocused: Bool

    init(courseId: UUID, holeNumber: Int, userLocation: CLLocation?, hole: Hole, strokes: [Stroke], targets: [Target], lastRealStroke: Stroke?, temporaryPenaltyPosition: CLLocationCoordinate2D?, heading: Double?, mapCamera: MapCameraInfo, isPlacingTarget: Bool, isPlacingPenalty: Bool, onTap: ((CLLocationCoordinate2D) -> Void)? = nil) {
        self.courseId = courseId
        self.holeNumber = holeNumber
        self.userLocation = userLocation
        self.hole = hole
        self.strokes = strokes
        self.targets = targets
        self.lastRealStroke = lastRealStroke
        self.temporaryPenaltyPosition = temporaryPenaltyPosition
        self.heading = heading
        self.mapCamera = mapCamera
        self.isPlacingTarget = isPlacingTarget
        self.isPlacingPenalty = isPlacingPenalty
        self.onTap = onTap
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = cacheManager.getImage(for: courseId, holeNumber: holeNumber),
                   let metadata = cacheManager.getMetadata(for: courseId, holeNumber: holeNumber) {

                    // Base satellite image with annotations
                    satelliteImageLayer(image: image, metadata: metadata, geometry: geometry)

                } else {
                    // Fallback: Loading state
                    loadingView
                }
            }
            .allowsHitTesting(isPlacingTarget || isPlacingPenalty)
            .onTapGesture { location in
                if isPlacingTarget || isPlacingPenalty,
                   let metadata = cacheManager.getMetadata(for: courseId, holeNumber: holeNumber) {
                    let coordinate = screenPositionToCoordinate(
                        screenPosition: location,
                        imageCenter: mapCamera.centerCoordinate,  // Use VIEW center, not image center
                        metersPerPixel: metadata.metersPerPixel,
                        imageSize: CGSize(width: CGFloat(metadata.pixelWidth), height: CGFloat(metadata.pixelHeight)),
                        screenSize: geometry.size,
                        bearing: mapCamera.bearing,
                        scale: scale
                    )
                    onTap?(coordinate)
                }
            }
        }
        .focusable(isPlacingTarget || isPlacingPenalty)
        .focused($isFocused)
        .modifier(ZoomCrownRotationModifier(scale: $scale))
        .onChange(of: isPlacingTarget) { _, newValue in
            if !newValue && !isPlacingPenalty {
                scale = 1.0  // Reset zoom when exiting placement mode
            }
        }
        .onChange(of: isPlacingPenalty) { _, newValue in
            if !newValue && !isPlacingTarget {
                scale = 1.0  // Reset zoom when exiting placement mode
            }
        }
    }

    // MARK: - Image Layer

    @ViewBuilder
    private func satelliteImageLayer(image: UIImage, metadata: SatelliteImageMetadata, geometry: GeometryProxy) -> some View {
        // Calculate offset between image center (hole) and view center (midpoint)
        // View center is mapCamera.centerCoordinate (midpoint between user and hole)
        // Image center is metadata.centerCoordinate (hole coordinate)
        let imageOffset = calculateImageOffset(
            imageCenter: metadata.centerCoordinate,
            viewCenter: mapCamera.centerCoordinate,
            metersPerPixel: metadata.metersPerPixel,
            screenSize: geometry.size,
            scale: scale
        )

        ZStack {
            // Background satellite image with offset
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                .offset(x: imageOffset.x, y: imageOffset.y)
                .rotationEffect(.degrees(mapCamera.bearing))
                .clipped()

            // Annotations overlay
            annotationsOverlay(metadata: metadata, geometry: geometry)
        }
    }

    // MARK: - Annotations

    @ViewBuilder
    private func annotationsOverlay(metadata: SatelliteImageMetadata, geometry: GeometryProxy) -> some View {
        ZStack {
            // Hole flag marker
            if !isPlacingTarget && !isPlacingPenalty, let holeCoord = hole.coordinate {
                annotationView(
                    for: holeCoord,
                    metadata: metadata,
                    geometry: geometry,
                    content: {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.yellow)
                    }
                )
            }

            // User location
            if let userLoc = userLocation, !isPlacingTarget && !isPlacingPenalty {
                annotationView(
                    for: userLoc.coordinate,
                    metadata: metadata,
                    geometry: geometry,
                    content: {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees((heading ?? 0) - mapCamera.bearing))
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                )
            }

            // Stroke markers
            if !isPlacingTarget && !isPlacingPenalty {
                ForEach(strokes, id: \.id) { stroke in
                    annotationView(
                        for: stroke.coordinate,
                        metadata: metadata,
                        geometry: geometry,
                        content: {
                            ZStack {
                                Circle()
                                    .fill(stroke.isPenalty ? .orange : .white)
                                    .frame(width: 20, height: 20)
                                    .opacity(0.85)
                                    .shadow(color: .black, radius: 2)

                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(stroke.isPenalty ? .white : .black)
                            }
                        }
                    )
                }
            }

            // Target markers
            if !isPlacingPenalty {
                ForEach(Array(targets.enumerated()), id: \.element.id) { _, target in
                    annotationView(
                        for: target.coordinate,
                        metadata: metadata,
                        geometry: geometry,
                        content: {
                            Image(systemName: "scope")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 2)
                        }
                    )
                }
            }

            // Temporary penalty position
            if let penaltyPos = temporaryPenaltyPosition, isPlacingPenalty {
                annotationView(
                    for: penaltyPos,
                    metadata: metadata,
                    geometry: geometry,
                    content: {
                        Circle()
                            .fill(.orange)
                            .frame(width: 28, height: 28)
                            .shadow(color: .black, radius: 2)
                    }
                )
            }
        }
    }

    // MARK: - Annotation Positioning

    @ViewBuilder
    private func annotationView<Content: View>(
        for coordinate: CLLocationCoordinate2D,
        metadata: SatelliteImageMetadata,
        geometry: GeometryProxy,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let position = coordinateToScreenPosition(
            coordinate: coordinate,
            imageCenter: mapCamera.centerCoordinate,  // Use VIEW center, not image center
            metersPerPixel: metadata.metersPerPixel,
            imageSize: CGSize(width: CGFloat(metadata.pixelWidth), height: CGFloat(metadata.pixelHeight)),
            screenSize: geometry.size,
            bearing: mapCamera.bearing,
            scale: scale
        )

        // Only show if position is within screen bounds
        if position.x >= 0 && position.x <= geometry.size.width &&
           position.y >= 0 && position.y <= geometry.size.height {
            content()
                .position(position)
        }
    }

    // MARK: - Coordinate Mapping

    /// Calculate the screen offset needed to display the image so that viewCenter appears at screen center
    /// even though the image is physically centered at imageCenter
    /// Note: This offset must be applied BEFORE rotation
    private func calculateImageOffset(
        imageCenter: CLLocationCoordinate2D,
        viewCenter: CLLocationCoordinate2D,
        metersPerPixel: Double,
        screenSize: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        // Calculate geographic offset (image center - view center)
        // We want to shift the image so that viewCenter appears at screen center
        // Since image is centered at imageCenter, we need to shift by (imageCenter - viewCenter)
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(imageCenter.latitude * .pi / 180.0)

        let deltaLat = imageCenter.latitude - viewCenter.latitude
        let deltaLon = imageCenter.longitude - viewCenter.longitude

        let metersNorth = deltaLat * metersPerDegreeLat
        let metersEast = deltaLon * metersPerDegreeLon

        // Convert to pixels on source image
        let pixelOffsetX = metersEast / metersPerPixel
        let pixelOffsetY = -metersNorth / metersPerPixel  // Negative because Y increases downward

        // Convert to screen coordinates (scaled)
        let screenOffsetX = CGFloat(pixelOffsetX) * scale
        let screenOffsetY = CGFloat(pixelOffsetY) * scale

        return CGPoint(x: screenOffsetX, y: screenOffsetY)
    }

    private func screenPositionToCoordinate(
        screenPosition: CGPoint,
        imageCenter: CLLocationCoordinate2D,
        metersPerPixel: Double,
        imageSize: CGSize,
        screenSize: CGSize,
        bearing: Double,
        scale: CGFloat
    ) -> CLLocationCoordinate2D {
        var screenX = screenPosition.x
        var screenY = screenPosition.y

        // 1. Reverse rotation around center
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        let bearingRadians = bearing * .pi / 180.0  // Positive to reverse the rotation
        let cosTheta = cos(bearingRadians)
        let sinTheta = sin(bearingRadians)

        let translatedX = screenX - centerX
        let translatedY = screenY - centerY

        let unrotatedX = translatedX * cosTheta - translatedY * sinTheta
        let unrotatedY = translatedX * sinTheta + translatedY * cosTheta

        screenX = unrotatedX + centerX
        screenY = unrotatedY + centerY

        // 2. Reverse scale to get pixels on source image
        let scaleX = (screenSize.width / imageSize.width) * scale
        let scaleY = (screenSize.height / imageSize.height) * scale

        let pixelX = screenX / scaleX
        let pixelY = screenY / scaleY

        // 3. Convert pixels to meters offset from image center
        let pixelOffsetX = pixelX - (imageSize.width / 2)
        let pixelOffsetY = pixelY - (imageSize.height / 2)

        let metersEast = Double(pixelOffsetX) * metersPerPixel
        let metersNorth = -Double(pixelOffsetY) * metersPerPixel  // Negative because Y increases downward

        // 4. Convert meters to coordinate offset
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(imageCenter.latitude * .pi / 180.0)

        let deltaLat = metersNorth / metersPerDegreeLat
        let deltaLon = metersEast / metersPerDegreeLon

        return CLLocationCoordinate2D(
            latitude: imageCenter.latitude + deltaLat,
            longitude: imageCenter.longitude + deltaLon
        )
    }

    private func coordinateToScreenPosition(
        coordinate: CLLocationCoordinate2D,
        imageCenter: CLLocationCoordinate2D,
        metersPerPixel: Double,
        imageSize: CGSize,
        screenSize: CGSize,
        bearing: Double,
        scale: CGFloat
    ) -> CGPoint {
        // 1. Calculate meters offset from image center
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(imageCenter.latitude * .pi / 180.0)

        let deltaLat = coordinate.latitude - imageCenter.latitude
        let deltaLon = coordinate.longitude - imageCenter.longitude

        let metersNorth = deltaLat * metersPerDegreeLat
        let metersEast = deltaLon * metersPerDegreeLon

        // 2. Convert to pixels on source image
        let pixelX = (metersEast / metersPerPixel) + (imageSize.width / 2)
        let pixelY = -(metersNorth / metersPerPixel) + (imageSize.height / 2)

        // 3. Scale to screen size
        // With .fit mode, image scales to fit within frame of (screenSize * scale)
        let scaleX = (screenSize.width / imageSize.width) * scale
        let scaleY = (screenSize.height / imageSize.height) * scale

        var screenX = pixelX * scaleX
        var screenY = pixelY * scaleY

        // 4. Apply rotation around center
        let centerX = screenSize.width / 2
        let centerY = screenSize.height / 2

        let bearingRadians = -bearing * .pi / 180.0
        let cosTheta = cos(bearingRadians)
        let sinTheta = sin(bearingRadians)

        let translatedX = screenX - centerX
        let translatedY = screenY - centerY

        let rotatedX = translatedX * cosTheta - translatedY * sinTheta
        let rotatedY = translatedX * sinTheta + translatedY * cosTheta

        screenX = rotatedX + centerX
        screenY = rotatedY + centerY

        return CGPoint(x: screenX, y: screenY)
    }

    // MARK: - Loading View

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading Satellite")
                .font(.caption2)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
