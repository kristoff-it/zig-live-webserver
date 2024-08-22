let mainframe = document.getElementById("mainframe");
let navbar = document.getElementById("navbar");

let last_path_set = null;

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
function newSocket() {
    socket = new WebSocket("ws://" + window.location.host + "/__live_webserver/ws");

    socket.addEventListener("error", (event) => {
        console.log("error", event);
    });
    socket.addEventListener("open", (event) => {
        console.log("connected");
        socket.send("Hello WS");
    });

    // Listen for messages
    socket.addEventListener("message", (event) => {
        console.log("message", event);
    });
    socket.addEventListener("close", (event) => {
        console.log("close", event);
    });
}

newSocket();
