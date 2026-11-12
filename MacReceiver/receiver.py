"""Receive paired RGB and LiDAR frames and render instance contours on the Mac."""
import argparse
from colorsys import hsv_to_rgb
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from threading import Condition, Event, Thread
from time import perf_counter

import cv2
import numpy as np
from ultralytics import YOLO


class LatestFrame:
    def __init__(self):
        self.condition = Condition()
        self.frame = None

    def put(self, frame):
        with self.condition:
            self.frame = frame
            self.condition.notify()

    def take(self):
        with self.condition:
            self.condition.wait_for(lambda: self.frame is not None, timeout=0.05)
            frame, self.frame = self.frame, None
            return frame


def decode(packet):
    header, payload = packet.split(b"\n", 1)
    info = json.loads(header)
    jpeg_end = info["jpegBytes"]
    w, h = info["depthWidth"], info["depthHeight"]
    if not (0 < jpeg_end <= len(payload) and 0 <= w <= 2048 and 0 <= h <= 2048):
        raise ValueError("Invalid RGB-D dimensions")
    if len(payload) - jpeg_end != w * h * 2:
        raise ValueError("Incomplete depth map")
    image = cv2.imdecode(np.frombuffer(payload[:jpeg_end], np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("Invalid JPEG")
    depth = np.frombuffer(payload[jpeg_end:], "<f2").reshape(h, w) if w and h else None
    if depth is not None and w > h and image.shape[0] > image.shape[1]:
        depth = np.rot90(depth, -1)
    turns = info.get("quarterTurns", 0) % 4
    if turns:
        image = np.ascontiguousarray(np.rot90(image, turns))
        if depth is not None:
            depth = np.rot90(depth, turns)
        for _ in range(turns):
            info["cx"], info["cy"] = info["cy"], info["width"] - info["cx"]
            info["width"], info["height"] = info["height"], info["width"]
            info["fx"], info["fy"] = info["fy"], info["fx"]
    return image, depth, info


def measure(mask, depth, info):
    if depth is None:
        return None
    height, width = depth.shape
    # Area averaging rejects boundary cells that include substantial background.
    interior = cv2.resize(mask.astype(np.float32), (width, height), interpolation=cv2.INTER_AREA) >= 0.8
    ys, xs = np.nonzero(interior & np.isfinite(depth) & (depth > 0))
    if len(xs) < 5:
        return None
    rx = ((xs + 0.5) * info["width"] / width - info["cx"]) / info["fx"]
    ry = ((ys + 0.5) * info["height"] / height - info["cy"]) / info["fy"]
    return float(np.median(depth[ys, xs] * np.sqrt(1 + rx**2 + ry**2)))


def render(image, depth, info, result):
    if result.masks is None:
        return 0
    masks = result.masks.data.cpu().numpy()
    labels = result.boxes.cls.cpu().numpy()
    confidence = result.boxes.conf.cpu().numpy()
    for mask, class_id, score in zip(masks, labels, confidence):
        binary = mask.astype(np.uint8)
        contours, _ = cv2.findContours(binary, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        contours = [c for c in contours if cv2.contourArea(c) >= 12]
        if not contours:
            continue
        meters = measure(binary, depth, info)
        color = (180, 180, 180)
        if meters is not None:
            hue = np.clip((meters - 0.5) / 2.5, 0, 1) / 3
            color = tuple(int(c * 255) for c in reversed(hsv_to_rgb(hue, 0.9, 1)))
        cv2.drawContours(image, contours, -1, color, 2, cv2.LINE_AA)
        x, y, _, _ = cv2.boundingRect(max(contours, key=cv2.contourArea))
        distance = f"{meters:.2f} m" if meters is not None else "-- m"
        caption = f"{result.names[int(class_id)]} {score:.0%} | {distance}"
        origin = (x, max(y - 7, 18))
        cv2.putText(image, caption, origin, cv2.FONT_HERSHEY_SIMPLEX, 0.54, (0, 0, 0), 4, cv2.LINE_AA)
        cv2.putText(image, caption, origin, cv2.FONT_HERSHEY_SIMPLEX, 0.54, color, 1, cv2.LINE_AA)
    return len(masks)


def run(args):
    model = YOLO(args.model)
    latest = LatestFrame()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.settimeout(4)

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if self.path != "/frame" or not 0 < length <= 4_000_000:
                self.send_error(400)
                return
            packet = self.rfile.read(length)
            if len(packet) != length:
                self.send_error(400)
                return
            latest.put(packet)
            self.send_response(204)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    Thread(target=server.serve_forever, daemon=True).start()
    print(f"Listening on {args.bind}:{args.port} using {args.model} ({args.device})", flush=True)
    from window import show_preview

    rendered = LatestFrame()
    stopped = Event()

    def process_frames():
        while not stopped.is_set():
            packet = latest.take()
            if packet is None:
                continue
            try:
                image, depth, info = decode(packet)
                start = perf_counter()
                result = model.predict(image, imgsz=args.size, device=args.device, conf=0.25,
                                       retina_masks=True, verbose=False)[0]
                count = render(image, depth, info, result)
                elapsed = (perf_counter() - start) * 1000
                cv2.putText(image, f"{count} objects | {elapsed:.0f} ms", (12, 28),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2, cv2.LINE_AA)
                encoded, jpeg = cv2.imencode(".jpg", image)
                if encoded:
                    rendered.put(jpeg.tobytes())
                if args.once:
                    print(f"{count} objects, {elapsed:.0f} ms, depth {depth is not None}", flush=True)
                    stopped.set()
            except Exception as exc:
                print(f"Dropped frame: {exc}", flush=True)

    Thread(target=process_frames, daemon=True).start()
    try:
        show_preview(rendered, stopped)
    finally:
        stopped.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", default="yolo26n-seg.pt")
    parser.add_argument("--device", default="mps")
    parser.add_argument("--size", type=int, default=640)
    parser.add_argument("--once", action="store_true")
    run(parser.parse_args())
