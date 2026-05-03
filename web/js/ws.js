export function connectWebSocket({ url, onMessage, setStatus }) {
  let socket = null;

  function connect() {
    setStatus("", "connecting…");
    socket = new WebSocket(url);
    socket.onopen = () => setStatus("connected", "live");
    socket.onclose = () => {
      setStatus("error", "disconnected");
      setTimeout(connect, 1500);
    };
    socket.onerror = () => setStatus("error", "error");
    socket.onmessage = (event) => {
      if (event.data.indexOf("text_delta") > 0 ||
          event.data.indexOf("argument_delta") > 0) {
        console.log(
          "[" + performance.now().toFixed(1) + "ms] ws message (" +
          event.data.length + " bytes)"
        );
      }
      onMessage(JSON.parse(event.data));
    };
  }

  connect();

  return {
    get readyState() {
      return socket ? socket.readyState : WebSocket.CLOSED;
    },
    send(payload) {
      socket.send(payload);
    },
    sendJSON(payload) {
      socket.send(JSON.stringify(payload));
    }
  };
}
