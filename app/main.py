from flask import Flask, request, render_template
import logging
import time

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)
logger = logging.getLogger(__name__)

REQUEST_COUNT = 0
START_TIME = time.time()

@app.route("/")
def index():
    global REQUEST_COUNT
    REQUEST_COUNT += 1
    logger.info("route=/ method=GET event=page_view")
    return render_template("index.html")

@app.route("/echo", methods=["POST"])
def echo():
    global REQUEST_COUNT
    REQUEST_COUNT += 1
    data = request.form.get("message", "")
    logger.info(f"route=/echo method=POST event=echo length={len(data)}")
    return f"You said: {data}\nAha! I knew you were going to say that. :)"

@app.route("/healthz")
def health():
    return {"status": "ok"}, 200

@app.route("/metrics")
def metrics():
    uptime = int(time.time() - START_TIME)
    return (
        f"custom_requests_total {REQUEST_COUNT}\n"
        f"custom_uptime_seconds {uptime}\n",
        200,
        {"Content-Type": "text/plain"}
    )

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
