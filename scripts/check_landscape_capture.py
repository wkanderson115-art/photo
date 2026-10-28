#!/usr/bin/env python3
"""Cross-file regression checks for the 4:3 landscape capture path.

This does not replace an iPhone camera test.  It makes sure a future edit cannot
quietly restore the old bug where the interface rotated but the local result was
cropped with the portrait 3:4 aspect.
"""

from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "OutdoorPhotoAssistant"


def text(relative: str) -> str:
    return (APP / relative).read_text(encoding="utf-8")


checks: list[tuple[bool, str]] = []


def check(condition: bool, label: str) -> None:
    checks.append((condition, label))
    print(("PASS  " if condition else "FAIL  ") + label)


info = plistlib.loads((APP / "Info.plist").read_bytes())
orientations = set(info.get("UISupportedInterfaceOrientations", []))
check("UIInterfaceOrientationLandscapeLeft" in orientations, "Info.plist allows left landscape")
check("UIInterfaceOrientationLandscapeRight" in orientations, "Info.plist allows right landscape")

app = text("App/OutdoorPhotoAssistantApp.swift")
policy = text("App/OrientationPolicy.swift")
view = text("Features/Capture/CaptureView.swift")
layout = text("Features/Capture/CaptureLayout.swift")
camera = text("Core/Camera/CameraService.swift")
processor = text("Core/Analysis/PhotoPostProcessor.swift")
library = text("Core/Storage/PhotoLibraryService.swift")

check("@UIApplicationDelegateAdaptor(AppDelegate.self)" in app, "app delegate supplies orientation mask")
check("requestGeometryUpdate" in policy and ".allButUpsideDown" in view,
      "camera screen requests landscape geometry")
check("landscape ? 4.0 / 3.0 : 3.0 / 4.0" in layout, "still frame is fixed at 4:3 / 3:4")
check("normalizedRotationAngle" in layout and "isLandscape(rotationAngle:" in layout,
      "fractional device rotation settles to a quarter turn")
check("AVCaptureDevice.RotationCoordinator" in camera, "camera follows physical device rotation")
check("photoOutput.connection(with: .video)" in camera and "connection.videoRotationAngle = angle" in camera,
      "photo output receives the rotation angle")
check("videoOutput.connection(with: .video)" in camera, "analysis frames receive the same rotation")
check("uiView.previewLayer.connection" in camera and "camera.previewRotationAngle" in camera,
      "preview layer follows the camera rotation")
check("fileDataRepresentation()" in camera, "original photo bytes and EXIF are retained")
check("displayPixelSize" in camera and "image.imageOrientation" in camera,
      "captured aspect applies EXIF orientation")
check("preparedOptions.outputAspect" in view and "shot.displayAspect" in view,
      "post-processing follows the actual captured photo aspect")
check("outputAspect: Double(activeCaptureAspect)" in view,
      "live render options follow the active capture direction")
check("CIImage(cgImage: cg).oriented" in processor,
      "post-processing rotates pixels upright before the 4:3 crop")
check("originalData: originalData" in library and "styledImage" in library,
      "gallery stores the original and the rendered result separately")
check("横拍 4:3 已保存到图库" in view, "successful landscape save is visible to the user")

failed = [label for ok, label in checks if not ok]
print(f"\nLandscape capture checks: {len(checks) - len(failed)}/{len(checks)} passed")
if failed:
    raise SystemExit("Failed: " + "; ".join(failed))
