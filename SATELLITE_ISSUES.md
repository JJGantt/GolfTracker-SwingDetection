# Satellite View Logic Issues

## Critical Issues Found

### Issue 1: Large Image Metadata Mismatch ⚠️ CRITICAL
**Location**: `SatelliteCacheManager.swift:36-49`

**Problem**:
The `LargeSatelliteImageMetadata` is created using default init parameters, but the actual downloaded image uses different dimensions:
- Metadata init defaults: `radiusMeters=1500m`, `pixelWidth=3000`, `pixelHeight=3000`
- Actual download: `radiusMeters=1000m`, `size=2000x2000`

**Impact**:
The metadata incorrectly describes the image dimensions. While `metersPerPixel` happens to be the same (1.0) due to the ratio, any code reading the metadata will think the image is 3000x3000 when it's actually 2000x2000.

**Fix**:
```swift
// Line 36: Pass actual parameters to init
let metadata = LargeSatelliteImageMetadata(
    center: centerCoordinate,
    radiusMeters: 1000.0,  // Match actual download
    pixelWidth: 2000,       // Match actual download
    pixelHeight: 2000       // Match actual download
)
```

---

### Issue 2: Image Aspect Ratio Distortion ⚠️ MAJOR
**Location**: `SatelliteImageView.swift:66-71`

**Problem**:
```swift
Image(uiImage: image)
    .resizable()
    .aspectRatio(contentMode: .fill)
    .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
    .rotationEffect(.degrees(mapCamera.bearing))
    .clipped()
```

The satellite image is 2000x2000 (square), but Apple Watch screen is rectangular (~184x224). Using `.fill` mode causes the image to be cropped to fill the frame, not uniformly scaled.

**Impact**:
The coordinate transformation at `coordinateToScreenPosition()` lines 225-226 assumes uniform scaling:
```swift
let scaleX = (screenSize.width / imageSize.width) * scale
let scaleY = (screenSize.height / imageSize.height) * scale
```

With `.fill`, the image is actually scaled by `max(screenSize.width/imageSize.width, screenSize.height/imageSize.height)` and then cropped. This causes a mismatch between where the coordinate transformation thinks pixels are vs where they actually are.

**Fix**: Change to `.fit` mode:
```swift
Image(uiImage: image)
    .resizable()
    .aspectRatio(contentMode: .fit)  // Change from .fill to .fit
```

And adjust coordinate calculation to account for the actual image bounds within the frame.

---

### Issue 3: Double Scaling Application ⚠️ MAJOR
**Location**: `SatelliteImageView.swift:69, 225-226`

**Problem**:
The scale is applied twice:
1. Line 69: `.frame(width: geometry.size.width * scale, height: geometry.size.height * scale)` - image frame is scaled
2. Lines 225-226: `let scaleX = (screenSize.width / imageSize.width) * scale` - pixel coordinates are scaled again

**Impact**:
When Digital Crown zoom is 2.0x:
- Image frame is 2x larger
- Pixel coordinates are also multiplied by 2x
- Result: annotations appear 4x scaled instead of 2x, causing massive position errors

**Example**:
- Image: 2000x2000px
- Screen: 184x224px
- User zooms to scale=2.0
- Image frame becomes: 184*2 = 368px wide
- But scaleX = (184/2000) * 2.0 = 0.184, so a pixel at x=1000 becomes screenX = 1000 * 0.184 = 184px
- This is correct WITHOUT the frame scaling, but WITH frame scaling the image is actually 368px wide, so the annotation should be at 368px, not 184px

**Fix**: Remove scale from the coordinate calculation since it's already in the frame:
```swift
let scaleX = screenSize.width / imageSize.width  // Remove * scale
let scaleY = screenSize.height / imageSize.height  // Remove * scale
```

---

### Issue 4: Image Center vs Camera Center Confusion ⚠️ MEDIUM
**Location**: `ActiveRoundView.swift:713-714` and `SatelliteImageView.swift:201-248`

**Problem**:
Two different "center" coordinates are used:
1. **Image center** (`metadata.centerCoordinate`): The hole coordinate - what the satellite image is actually centered on
2. **Camera center** (`mapCamera.centerCoordinate`): A calculated point between user and hole (0.45, 0.5 offset)

The `coordinateToScreenPosition()` function uses `imageCenter` parameter (line 203), which is correctly passed as `metadata.centerCoordinate` (the hole). However, the `mapCamera.centerCoordinate` is calculated but never actually used in the transformation.

**Impact**:
The camera center calculation appears to be dead code. The coordinate transformation is working relative to the hole (image center), which might not produce the desired framing.

**Fix Options**:
1. If the intent is to frame between user and hole: Use `mapCamera.centerCoordinate` as the imageCenter parameter, but then the image itself needs to be panned to center on that point
2. If the intent is to keep image centered on hole: Remove the unused camera center calculation

---

### Issue 5: Cropped Images May Not Be Centered on Hole ⚠️ MEDIUM
**Location**: `SatelliteCacheManager.swift:203-233`

**Problem**:
When cropping a hole image from the large image:
```swift
// Lines 229-230: Clamp to image bounds
let clampedX = max(0, min(cropX, largeImageSize.width - cropSize.width))
let clampedY = max(0, min(cropY, largeImageSize.height - cropSize.height))
```

If a hole is near the edge of the large image, the crop rect is clamped to stay within bounds. This means the cropped image is NOT actually centered on the hole coordinate.

However, line 156:
```swift
let metadata = SatelliteImageMetadata(courseId: courseId, holeNumber: hole.number, center: hole.coordinate)
```

The metadata claims the image is centered on `hole.coordinate`, but it might actually be offset if clamping occurred.

**Impact**:
For holes near the edge of the large image area, all annotations will be offset because the metadata center doesn't match the actual image center.

**Fix**: Calculate the actual center of the clamped crop rect and use that as the metadata center:
```swift
let actualCenterX = (clampedX + cropSize.width / 2)
let actualCenterY = (clampedY + cropSize.height / 2)
// Convert back to coordinate and use as metadata center
```

---

### Issue 6: Rotation Origin Mismatch ⚠️ MINOR
**Location**: `SatelliteImageView.swift:70, 231-246`

**Problem**:
- Line 70: Image is rotated with `.rotationEffect(.degrees(mapCamera.bearing))` - SwiftUI rotates around the view's center
- Lines 231-246: Annotations are rotated around `screenSize.width/2, screenSize.height/2`

These should be the same point, but if the image is scaled or offset differently than expected, the rotation centers could diverge.

**Impact**:
Annotations might rotate around a slightly different point than the image, causing position drift when bearing changes.

**Fix**:
Ensure both rotations happen around the exact same point, or apply rotation as a single transform to a container view.

---

### Issue 7: No Hit Testing for Placement Modes ⚠️ MINOR
**Location**: `SatelliteImageView.swift:44`

**Problem**:
Unlike the standard map view (ActiveRoundView.swift:935), the satellite view doesn't implement tap gesture handling for placing targets or penalties.

**Impact**:
Users cannot place targets or penalties when satellite mode is enabled.

**Fix**: Add MapReader-style tap gesture handling similar to the standard map view.

---

## Summary

**Critical Issues** (Must fix immediately):
1. Large image metadata mismatch
2. Image aspect ratio distortion with `.fill` mode
3. Double scaling causing massive position errors

**Major Issues** (Fix soon):
4. Camera center confusion/unused code
5. Cropped images not centered on claimed coordinate

**Minor Issues** (Nice to have):
6. Rotation origin potential mismatch
7. No tap gesture support for placement modes

## Testing Recommendations

After fixes:
1. Verify user location marker stays on user position when moving
2. Verify hole flag marker aligns with actual hole
3. Verify stroke markers appear at correct positions
4. Test Digital Crown zoom - annotations should stay in place
5. Test rotation with bearing changes - annotations should rotate correctly
6. Test holes near edge of course area for proper cropping
