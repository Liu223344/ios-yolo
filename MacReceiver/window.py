"""Native macOS preview with proportional sizing and a centered image."""
from AppKit import (
    NSApplication, NSApplicationActivationPolicyRegular, NSBackingStoreBuffered,
    NSColor, NSImage, NSImageAlignCenter, NSImageScaleProportionallyUpOrDown,
    NSImageView, NSMakeRect, NSViewHeightSizable, NSViewWidthSizable, NSWindow,
    NSWindowStyleMaskClosable, NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable, NSWindowStyleMaskTitled, NSWindowCollectionBehaviorFullScreenPrimary,
)
from Foundation import NSData, NSObject, NSTimer


class PreviewController(NSObject):
    def tick_(self, timer):
        with self.frames.condition:
            jpeg, self.frames.frame = self.frames.frame, None
        if jpeg is not None:
            data = NSData.dataWithBytes_length_(jpeg, len(jpeg))
            image = NSImage.alloc().initWithData_(data)
            if image is not None:
                self.image_view.setImage_(image)
                self.window.setTitle_("YOLO26 LiDAR · 实时轮廓")
        if self.stopped.is_set():
            NSApplication.sharedApplication().terminate_(None)

    def applicationShouldHandleReopen_hasVisibleWindows_(self, app, visible):
        self.window.makeKeyAndOrderFront_(None)
        return True


def show_preview(frames, stopped):
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)
    style = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
             | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
    window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        NSMakeRect(0, 0, 720, 620), style, NSBackingStoreBuffered, False
    )
    window.setReleasedWhenClosed_(False)
    window.setCollectionBehavior_(NSWindowCollectionBehaviorFullScreenPrimary)
    window.setBackgroundColor_(NSColor.blackColor())
    window.setTitle_("YOLO26 LiDAR · 等待 iPhone 连接")
    content = window.contentView()
    image_view = NSImageView.alloc().initWithFrame_(content.bounds())
    image_view.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
    image_view.setImageScaling_(NSImageScaleProportionallyUpOrDown)
    image_view.setImageAlignment_(NSImageAlignCenter)
    content.addSubview_(image_view)

    controller = PreviewController.alloc().init()
    controller.frames = frames
    controller.stopped = stopped
    controller.image_view = image_view
    controller.window = window
    app.setDelegate_(controller)
    window.center()
    window.makeKeyAndOrderFront_(None)
    app.activateIgnoringOtherApps_(True)
    timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        1 / 30, controller, "tick:", None, True
    )
    app.run()
    timer.invalidate()
