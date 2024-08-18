let mainframe = document.getElementById("mainframe");

mainframe.addEventListener("load", function () {
	hash_to_ignore = mainframe.contentWindow.location.pathname;
	window.location.hash = mainframe.contentWindow.location.pathname;
});

var hash_to_ignore = null;

window.addEventListener("hashchange", function() {
	if (hash_to_ignore == window.location.hash) {
		mainframe.contentWindow.location = window.location;
		mainframe.contentWindow.location.pathname = window.location.hash;
	}
});
mainframe.contentWindow.location.pathname = window.location.hash;
