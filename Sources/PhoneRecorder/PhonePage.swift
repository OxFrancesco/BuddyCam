// The single-file page served to the phone. Same design system as the app:
// black, white 3 px outlines, coral selection, hard offset shadows.
enum PhonePage {
    static let html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>BuddyCam</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { height: 100%; background: #000; color: #fff;
    font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace;
    -webkit-text-size-adjust: 100%; }
video { position: fixed; inset: 0; width: 100%; height: 100%;
    object-fit: contain; background: #000; }
#status { position: fixed; top: 16px; left: 16px; z-index: 2;
    font-size: 12px; font-weight: 700; letter-spacing: 1.4px; text-transform: uppercase;
    padding: 4px 8px; background: #000; }
#bar { position: fixed; left: 0; right: 0; bottom: 20px; z-index: 2;
    display: flex; justify-content: center; align-items: center; gap: 16px; padding: 0 16px; }
.seg { display: flex; border: 3px solid #fff; background: #000; }
.seg button { font: inherit; font-size: 11px; font-weight: 700; letter-spacing: 0.55px;
    text-transform: uppercase; color: #fff; background: #000; border: 0;
    padding: 0 16px; height: 36px; cursor: pointer;
    transition: color 180ms cubic-bezier(0.23, 1, 0.32, 1),
        background 180ms cubic-bezier(0.23, 1, 0.32, 1); }
.seg button + button { border-left: 2px solid #fff; }
.seg button.on { background: #D6544B; color: #000; }
.btn { font: inherit; font-size: 11px; font-weight: 700; letter-spacing: 0.55px;
    text-transform: uppercase; color: #fff; background: #000;
    border: 3px solid #fff; padding: 0 16px; height: 36px; cursor: pointer;
    box-shadow: 4px 4px 0 #fff;
    transition: transform 160ms cubic-bezier(0.23, 1, 0.32, 1),
        box-shadow 160ms cubic-bezier(0.23, 1, 0.32, 1),
        color 180ms cubic-bezier(0.23, 1, 0.32, 1); }
.btn:hover { color: #D6544B; }
.btn:active { transform: translate(4px, 4px); box-shadow: 0 0 0 #fff; }
[hidden] { display: none !important; }
</style>
</head>
<body>
<video id="video" autoplay playsinline muted></video>
<div id="status" aria-live="polite">CONNECTING</div>
<div id="bar">
    <button id="retry" class="btn" aria-label="Retry camera access" hidden>Retry</button>
    <div class="seg" role="group" aria-label="Video size">
        <button class="size" data-h="480" aria-label="480 lines">480</button>
        <button class="size on" data-h="720" aria-label="720 lines">720</button>
        <button class="size" data-h="1080" aria-label="1080 lines">1080</button>
    </div>
    <button id="flip" class="btn" aria-label="Flip camera" hidden>Flip</button>
</div>
<script>
(function () {
    var video = document.getElementById('video');
    var status = document.getElementById('status');
    var retry = document.getElementById('retry');
    var flip = document.getElementById('flip');
    var sizes = document.querySelectorAll('.size');
    var canvas = document.createElement('canvas');
    var ctx = canvas.getContext('2d');
    var facing = 'environment';
    var idealHeight = 720;
    var stream = null;
    var ws = null;
    var wsOpen = false;
    var encoding = false;
    var sent = 0;
    var retries = 0;
    var needReconnect = false;
    var reconnectTimer = 0;

    function setStatus(text) { status.textContent = text; }

    function keepAwake() {
        if (navigator.wakeLock && navigator.wakeLock.request) {
            navigator.wakeLock.request('screen').then(null, function () {});
        }
    }

    function updateDevices() {
        if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
        navigator.mediaDevices.enumerateDevices().then(function (devices) {
            var count = 0;
            for (var i = 0; i < devices.length; i++) {
                if (devices[i].kind === 'videoinput') count++;
            }
            flip.hidden = count < 2;
        }, function () {});
    }

    function connect() {
        if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
        var proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
        ws = new WebSocket(proto + location.host + '/ws');
        ws.binaryType = 'arraybuffer';
        ws.onopen = function () { retries = 0; wsOpen = true; };
        ws.onerror = function () {};
        ws.onclose = function () {
            wsOpen = false;
            scheduleReconnect();
        };
    }

    function scheduleReconnect() {
        if (!stream) return;
        if (document.hidden) { needReconnect = true; return; }
        setStatus('RECONNECTING');
        var delay = Math.min(1000 * Math.pow(2, retries), 8000);
        retries = Math.min(retries + 1, 3);
        clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(connect, delay);
    }

    function startCamera() {
        retry.hidden = true;
        if (!window.isSecureContext || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
            setStatus('OPEN THIS PAGE OVER HTTPS');
            return;
        }
        if (stream) {
            stream.getTracks().forEach(function (track) { track.stop(); });
            stream = null;
        }
        navigator.mediaDevices.getUserMedia({
            video: {
                facingMode: { ideal: facing },
                width: { ideal: Math.round(idealHeight * 16 / 9) },
                height: { ideal: idealHeight },
                frameRate: { ideal: 30 }
            },
            audio: false
        }).then(function (next) {
            stream = next;
            video.srcObject = next;
            updateDevices();
            connect();
        }, function () {
            setStatus('CAMERA BLOCKED');
            retry.hidden = false;
        });
    }

    var pumpPending = false;
    var lastEncode = 0;

    function pump() {
        schedulePump();
        if (!stream || !video.videoWidth || !wsOpen || !ws || ws.readyState !== 1) return;
        if (encoding || ws.bufferedAmount > 262144) return;
        var now = Date.now();
        if (now - lastEncode < 33) return;
        lastEncode = now;
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        ctx.drawImage(video, 0, 0);
        encoding = true;
        canvas.toBlob(function (blob) {
            encoding = false;
            if (blob && ws && ws.readyState === 1) {
                ws.send(blob);
                sent++;
            }
        }, 'image/jpeg', 0.7);
    }

    function schedulePump() {
        if (pumpPending) return;
        pumpPending = true;
        if (video.requestVideoFrameCallback) {
            video.requestVideoFrameCallback(function () { pumpPending = false; pump(); });
        } else {
            requestAnimationFrame(function () { pumpPending = false; pump(); });
        }
    }

    setInterval(function () {
        // Kick the pump in case a pending frame callback was dropped by a
        // camera restart; duplicate chains collapse through pumpPending.
        if (stream) { pumpPending = false; schedulePump(); }
        if (!stream || !wsOpen) { sent = 0; return; }
        var w = video.videoWidth, h = video.videoHeight;
        setStatus('LIVE' + (w ? ' · ' + w + '×' + h : '') + ' · ' + sent + ' FPS');
        sent = 0;
    }, 1000);

    document.addEventListener('visibilitychange', function () {
        if (document.hidden) return;
        if (needReconnect || (ws && ws.readyState === 3)) {
            needReconnect = false;
            retries = 0;
            clearTimeout(reconnectTimer);
            connect();
        }
        keepAwake();
    });

    for (var i = 0; i < sizes.length; i++) {
        sizes[i].addEventListener('click', function () {
            var h = parseInt(this.getAttribute('data-h'), 10);
            if (h === idealHeight) return;
            idealHeight = h;
            for (var j = 0; j < sizes.length; j++) sizes[j].classList.remove('on');
            this.classList.add('on');
            startCamera();
        });
    }

    flip.addEventListener('click', function () {
        facing = facing === 'environment' ? 'user' : 'environment';
        startCamera();
    });

    retry.addEventListener('click', startCamera);

    keepAwake();
    schedulePump();
    startCamera();
})();
</script>
</body>
</html>
"""
}
