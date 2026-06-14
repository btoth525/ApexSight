import Foundation

// go2rtc 2.x WebRTC signaling + Aqara talkback injected HTML.
// Shared between DoorbellCallView (full-screen) and pre-warm (hidden 1×1).

enum DoorbellStream {

    static func webRTCHtml(wsURL: URL) -> String {
        let wsURLString = wsURL.absoluteString
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { background:#000; width:100vw; height:100vh; overflow:hidden; }
        video { width:100%; height:100%; object-fit:cover; display:block; }
        </style>
        </head>
        <body>
        <video id="v" autoplay playsinline></video>
        <script>
        (function() {
          // ── WebRTC receive (video + audio from doorbell) ───────────────────
          var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
          var ws = new WebSocket(\(JSON.stringify(wsURLString)));
          pc.ontrack = function(e) {
            var v = document.getElementById('v');
            if (!v.srcObject || v.srcObject !== e.streams[0]) v.srcObject = e.streams[0];
          };
          ws.onmessage = function(e) {
            try {
              var msg = JSON.parse(e.data);
              if (msg.type === 'webrtc/answer') {
                pc.setRemoteDescription({ type: 'answer', sdp: msg.value });
              } else if (msg.type === 'webrtc/candidate' && msg.value) {
                pc.addIceCandidate({ candidate: msg.value, sdpMid: '0' }).catch(function(){});
              }
            } catch(err) {}
          };
          pc.onicecandidate = function(e) {
            if (e.candidate && ws.readyState === 1) {
              ws.send(JSON.stringify({
                type: 'webrtc/candidate',
                value: e.candidate.candidate + '\\\\n' + (e.candidate.sdpMLineIndex || 0)
              }));
            }
          };
          ws.onopen = function() {
            try {
              pc.addTransceiver('video', { direction: 'recvonly' });
              pc.addTransceiver('audio', { direction: 'recvonly' });
              pc.createOffer()
                .then(function(o) { return pc.setLocalDescription(o).then(function() { return o; }); })
                .then(function(o) { ws.send(JSON.stringify({ type: 'webrtc/offer', value: o.sdp })); });
            } catch(err) {}
          };

          // ── Talkback (mic → audio proxy WebSocket) ─────────────────────────
          var _talkWs = null, _talkStream = null, _talkCtx = null, _talkNode = null;

          window._startTalkback = function(audioWsUrl) {
            if (_talkWs) return;
            navigator.mediaDevices.getUserMedia({
              audio: { sampleRate: 16000, channelCount: 1, echoCancellation: true, noiseSuppression: true }
            }).then(function(stream) {
              _talkStream = stream;
              _talkCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 16000 });
              var src = _talkCtx.createMediaStreamSource(stream);
              _talkNode = _talkCtx.createScriptProcessor(1024, 1, 1);
              _talkWs = new WebSocket(audioWsUrl);
              _talkWs.binaryType = 'arraybuffer';
              _talkNode.onaudioprocess = function(e) {
                if (!_talkWs || _talkWs.readyState !== 1) return;
                var f32 = e.inputBuffer.getChannelData(0);
                var i16 = new Int16Array(f32.length);
                for (var i = 0; i < f32.length; i++) {
                  i16[i] = Math.max(-32768, Math.min(32767, Math.round(f32[i] * 32767)));
                }
                _talkWs.send(i16.buffer);
              };
              src.connect(_talkNode);
              _talkNode.connect(_talkCtx.destination);
            }).catch(function(e) { console.error('talkback mic error', e); });
          };

          window._stopTalkback = function() {
            try { if (_talkNode)   { _talkNode.disconnect();   _talkNode   = null; } } catch(e) {}
            try { if (_talkCtx)    { _talkCtx.close();         _talkCtx    = null; } } catch(e) {}
            try { if (_talkStream) { _talkStream.getTracks().forEach(function(t){t.stop();}); _talkStream = null; } } catch(e) {}
            try { if (_talkWs)     { _talkWs.close();          _talkWs     = null; } } catch(e) {}
          };
        })();
        </script>
        </body>
        </html>
        """
    }

    // Encodes a JS string literal safely for injection into the HTML template.
    private static func JSON(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
