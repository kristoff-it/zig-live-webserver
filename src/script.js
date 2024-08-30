let mainframe = document.getElementById("mainframe");
let navbar = document.getElementById("navbar");

let last_path_set = null;
let unique_server_id = null;

function pathChange(source, path) {
    if (source === "hash" && path[0] == "#" && path.length > 1) {
        path = path.substring(1);
    }
    if (path === last_path_set) {
        return;
    }
    last_path_set = path;
    if (source !== "iframe") {
        mainframe.contentWindow.location.href = window.location.origin + (path.startsWith("/") ? "": "/") + path;
    }
    if (source !== "hash") {
        window.location.hash = path;
    }
    if (source !== "navbar") {
        navbar.value = path;
    }
}

mainframe.addEventListener("load", function () {
    pathChange("iframe", mainframe.contentWindow.location.pathname);
});
window.addEventListener("hashchange", function() {
    pathChange("hash", window.location.hash);
});
navbar.addEventListener("change", function() {
    pathChange("navbar", navbar.value);
});
pathChange("hash", window.location.hash);

let socket = null;
let reconnect_in_flight = false;
function newSocket() {
    reconnect_in_flight = false;
    socket = new WebSocket("ws://" + window.location.host + "/__live_webserver/ws");

    socket.addEventListener("error", (event) => {
        if (!reconnect_in_flight) {
            console.log("Websocket error, retrying in 3 seconds.", event);
            setTimeout(newSocket, 3000);
            reconnect_in_flight = true;
        }
    });
    socket.addEventListener("open", (event) => {
        console.log("connected");
    });

    // Listen for messages
    socket.addEventListener("message", (event) => {
        let msg = JSON.parse(event.data);
        if (msg.state === "unique_server_id") {
            if (unique_server_id === null) {
                unique_server_id = msg.id;
            } else {
                if (unique_server_id !== msg.id) {
                    window.location.reload();
                }
            }
        } else {
            console.log("unknown message", msg);
        }
    });
    socket.addEventListener("close", (event) => {
        if (!reconnect_in_flight) {
            console.log("Websocket closed, retrying in 3 seconds.", event);
            setTimeout(newSocket, 3000);
            reconnect_in_flight = true;
        }
    });
}

newSocket();

// TODO(https://github.com/ziglang/zig/issues/14233): remove this, and noop handler.
// Constantly send data so that Windows Zig doesn't block writing on read.  Yes, this is stupid.
function spam() {
    if (socket.readyState === WebSocket.OPEN) {
        socket.send("noop");
    }
}
setInterval(spam, 100);
