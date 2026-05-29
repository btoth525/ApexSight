export function buildWsUrl(baseUrl: string, token: string | null, camera: string): string {
  try {
    const url = new URL(baseUrl);
    const proto = url.protocol === "https:" ? "wss:" : "ws:";
    const tok = token ? `&token=${encodeURIComponent(token)}` : "";
    return `${proto}//${url.host}/live/webrtc/api/ws?src=${encodeURIComponent(camera)}${tok}`;
  } catch {
    return "";
  }
}

export function buildWebRTCHtml(wsUrl: string): string {
  return `<!DOCTYPE html>
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
  var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
  var ws = new WebSocket(${JSON.stringify(wsUrl)});
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
        value: e.candidate.candidate + '\\n' + (e.candidate.sdpMLineIndex || 0)
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
})();
</script>
</body>
</html>`;
}
