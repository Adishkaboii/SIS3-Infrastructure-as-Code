import json
import logging
import os
import signal
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("sis3")
PORT = int(os.environ.get("PORT", "8080"))
TOPIC_ARN = os.environ.get("TOPIC_ARN", "")
sns = boto3.client("sns") if TOPIC_ARN else None


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/health":
            self.respond(200, {"status": "healthy"})
        elif path == "/":
            self.respond(200, {"message": "SIS 3 Orders API on ECS Fargate", "status": "running"})
        else:
            self.respond(404, {"error": "Not found"})

    def do_POST(self):
        if urlsplit(self.path).path != "/orders":
            return self.respond(404, {"error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 65536:
                return self.respond(400, {"error": "Body must be 1..65536 bytes"})
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                return self.respond(400, {"error": "Expected JSON object"})
            order_id = body.get("orderId") or str(uuid.uuid4())
            if not isinstance(order_id, str) or not order_id.strip() or len(order_id) > 128:
                return self.respond(400, {"error": "Invalid orderId"})
            if sns is None:
                return self.respond(503, {"error": "TOPIC_ARN not configured"})
            event = {"eventType": "OrderPlaced", "orderId": order_id}
            sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(event))
            logger.info("PUBLISHED orderId=%s", order_id)
            self.respond(202, {"status": "accepted", "orderId": order_id})
        except (ValueError, json.JSONDecodeError):
            self.respond(400, {"error": "Invalid JSON"})
        except Exception:
            logger.exception("Publish failed")
            self.respond(503, {"error": "Message publish failed"})


server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

def shutdown(signum, frame):
    logger.info("SIGTERM received; stopping server")
    threading.Thread(target=server.shutdown, daemon=True).start()

signal.signal(signal.SIGTERM, shutdown)
logger.info("Listening on 0.0.0.0:%s", PORT)
try:
    server.serve_forever()
finally:
    server.server_close()
    logger.info("Server stopped")
