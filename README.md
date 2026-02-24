# HDR Viewer (macOS)

Native Swift macOS photo viewer focused on:
- Smooth folder navigation
- HDR-ready rendering path
- Fast decode and next/prev preloading
- Multiple formats including RAW camera files

## MVP Scope

- Folder browse + next/previous navigation
- Zoom and pan viewer interactions
- Thumbnail grid and filmstrip
- EXIF metadata panel
- Format support target: CR3/CR2, NEF, ARW, RAF, DNG, JPG, PNG, TIFF, HEIF

## Architecture

- `Browser`: folder indexing and filtering
- `Decode`: image decoding through ImageIO/CoreImage RAW pipeline
- `Cache`: in-memory NSCache for decoded images
- `Metadata`: EXIF extraction from CGImageSource
- `Viewer`: state and preloading orchestration
- `Render`: SwiftUI image view now, HDR Metal surface hook included for next phase

## Run

```bash
swift run HDRViewer
```

## Notes

- RAW support depends on macOS camera codec support and source files.
- HDR/EDR output is scaffolded with a render module; full EDR tuning/calibration is planned in next iteration.
