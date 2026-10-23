/* The smoke test: load a local page in a WebView and check what every process maps.
 *
 *   smoke <file:// URI> <expected title>
 *
 * Opens a window with a WebView on an ephemeral network session, loads the page, and waits
 * for the load to finish and the title to be the expected one. Then it reads /proc/<pid>/maps
 * of itself and of every process below it (the sandbox's bwrap, the web process, the network
 * process) and checks that every WebKit, JavaScriptCore and GTK library mapped anywhere is the
 * bundle's (/usr/lib/amber-webkit) or amber-gtk4's (/usr/lib/amber-gtk4). It exits 0 when the
 * page loaded, a web process and a network process ran from the bundle, and nothing else was
 * mapped; 1 otherwise, with one line saying what was wrong. tests/run-smoke runs it.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <gtk/gtk.h>
#include <webkit/webkit.h>

#define WEBKIT_DIR "/usr/lib/amber-webkit/"
#define GTK_DIR "/usr/lib/amber-gtk4/"
#define MAX_PROCS 256

typedef struct {
	const char *title;
	gboolean done;
	int status;
} Smoke;

static pid_t parent_of(pid_t pid) {
	char path[64], buf[512];
	snprintf(path, sizeof path, "/proc/%d/stat", pid);
	FILE *f = fopen(path, "r");
	if (!f) return -1;
	size_t n = fread(buf, 1, sizeof buf - 1, f);
	fclose(f);
	buf[n] = 0;
	/* The command name is in parentheses and may hold spaces; the fields after the last ')'
	 * are the state and then the parent's pid. */
	char *close = strrchr(buf, ')');
	if (!close) return -1;
	char state;
	int ppid;
	if (sscanf(close + 1, " %c %d", &state, &ppid) != 2) return -1;
	return ppid;
}

/* The program's name: argv[0]'s last part, which /proc/<pid>/comm cuts at 15 bytes. */
static void name_of(pid_t pid, char *out, size_t size) {
	char path[64], buf[4096];
	snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
	out[0] = 0;
	FILE *f = fopen(path, "r");
	if (!f) return;
	size_t n = fread(buf, 1, sizeof buf - 1, f);
	fclose(f);
	buf[n] = 0;
	const char *slash = strrchr(buf, '/');
	g_strlcpy(out, slash ? slash + 1 : buf, size);
}

/* Every process below `root`, found by walking each process's parent up to it. */
static int descendants(pid_t root, pid_t *out, int max) {
	int n = 0;
	DIR *d = opendir("/proc");
	if (!d) return 0;
	struct dirent *e;
	while ((e = readdir(d)) && n < max) {
		pid_t pid = (pid_t)atoi(e->d_name);
		if (pid <= 1 || pid == root) continue;
		for (pid_t p = parent_of(pid); p > 1; p = parent_of(p)) {
			if (p == root) {
				out[n++] = pid;
				break;
			}
		}
	}
	closedir(d);
	return n;
}

typedef struct {
	int webkit, jsc, gtk, wrong;
} Maps;

static gboolean has(const char *line, const char *lib) {
	return strstr(line, lib) != NULL;
}

/* Count what a process maps from the bundles, and print each WebKit or GTK library it maps
 * from anywhere else. */
static Maps check_maps(pid_t pid, const char *name) {
	Maps m = {0};
	char path[64], line[4096];
	snprintf(path, sizeof path, "/proc/%d/maps", pid);
	FILE *f = fopen(path, "r");
	if (!f) {
		printf("  %-22s %6d  maps not readable\n", name, pid);
		m.wrong = -1;
		return m;
	}
	char last[4096] = "";
	while (fgets(line, sizeof line, f)) {
		char *p = strchr(line, '/');
		if (!p) continue;
		p[strcspn(p, "\n")] = 0;
		if (strcmp(p, last) == 0) continue;
		g_strlcpy(last, p, sizeof last);
		gboolean wk = has(p, "libwebkitgtk-6.0.so"), js = has(p, "libjavascriptcoregtk-6.0.so");
		gboolean gt = has(p, "libgtk-4.so");
		if (!wk && !js && !gt) continue;
		const char *dir = gt ? GTK_DIR : WEBKIT_DIR;
		if (strncmp(p, dir, strlen(dir)) != 0) {
			printf("  %-22s %6d  maps %s, outside %s\n", name, pid, p, dir);
			m.wrong++;
			continue;
		}
		printf("  %-22s %6d  maps %s\n", name, pid, p);
		m.webkit += wk;
		m.jsc += js;
		m.gtk += gt;
	}
	fclose(f);
	return m;
}

static int check_processes(void) {
	pid_t self = getpid(), kids[MAX_PROCS];
	int n = descendants(self, kids, MAX_PROCS), status = 0, web = 0, net = 0;
	char name[256];

	Maps m = check_maps(self, "smoke");
	printf("  %-22s %6d  webkit %d, jsc %d, gtk %d mapped from the bundles\n", "smoke", self,
	       m.webkit, m.jsc, m.gtk);
	if (m.wrong || !m.webkit || !m.jsc || !m.gtk) status = 1;

	for (int i = 0; i < n; i++) {
		name_of(kids[i], name, sizeof name);
		m = check_maps(kids[i], name);
		if (m.wrong) status = 1;
		gboolean is_web = strcmp(name, "WebKitWebProcess") == 0;
		gboolean is_net = strcmp(name, "WebKitNetworkProcess") == 0;
		if (!is_web && !is_net && strcmp(name, "WebKitGPUProcess") != 0) continue;
		printf("  %-22s %6d  webkit %d, jsc %d, gtk %d mapped from the bundles\n", name, kids[i],
		       m.webkit, m.jsc, m.gtk);
		if (!m.webkit || !m.jsc) status = 1;
		web += is_web;
		net += is_net;
	}
	if (!web) printf("  no WebKitWebProcess ran below this process\n");
	if (!net) printf("  no WebKitNetworkProcess ran below this process\n");
	return (web && net) ? status : 1;
}

static void finish(Smoke *s, int status, const char *why) {
	if (s->done) return;
	if (why) printf("smoke: %s\n", why);
	s->status = status;
	s->done = TRUE;
}

static void on_title(WebKitWebView *view, GParamSpec *pspec, Smoke *s) {
	(void)pspec;
	const char *title = webkit_web_view_get_title(view);
	if (title && strcmp(title, s->title) == 0 && !webkit_web_view_is_loading(view)) {
		printf("smoke: loaded, title \"%s\"\n", title);
		finish(s, check_processes(), NULL);
	}
}

static void on_load(WebKitWebView *view, WebKitLoadEvent event, Smoke *s) {
	if (event == WEBKIT_LOAD_FINISHED) on_title(view, NULL, s);
}

static gboolean on_failed(WebKitWebView *view, WebKitLoadEvent event, char *uri, GError *error,
                          Smoke *s) {
	(void)view;
	(void)event;
	(void)uri;
	char why[512];
	snprintf(why, sizeof why, "the page did not load: %s", error->message);
	finish(s, 1, why);
	return TRUE;
}

static void on_crashed(WebKitWebView *view, WebKitWebProcessTerminationReason reason, Smoke *s) {
	(void)view;
	char why[128];
	snprintf(why, sizeof why, "the web process ended (reason %d)", reason);
	finish(s, 1, why);
}

static gboolean on_timeout(gpointer data) {
	finish(data, 1, "no page after 90 s");
	return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: smoke <file:// URI> <expected title>\n");
		return 2;
	}
	Smoke s = {.title = argv[2]};
	gtk_init();
	printf("smoke: GTK %u.%u.%u, WebKit %u.%u.%u\n", gtk_get_major_version(),
	       gtk_get_minor_version(), gtk_get_micro_version(), webkit_get_major_version(),
	       webkit_get_minor_version(), webkit_get_micro_version());

	WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
	GtkWidget *view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", session, NULL);
	GtkWidget *window = gtk_window_new();
	gtk_window_set_default_size(GTK_WINDOW(window), 800, 600);
	gtk_window_set_child(GTK_WINDOW(window), view);
	g_signal_connect(view, "load-changed", G_CALLBACK(on_load), &s);
	g_signal_connect(view, "notify::title", G_CALLBACK(on_title), &s);
	g_signal_connect(view, "load-failed", G_CALLBACK(on_failed), &s);
	g_signal_connect(view, "web-process-terminated", G_CALLBACK(on_crashed), &s);
	g_timeout_add_seconds(90, on_timeout, &s);
	gtk_window_present(GTK_WINDOW(window));
	webkit_web_view_load_uri(WEBKIT_WEB_VIEW(view), argv[1]);

	while (!s.done) g_main_context_iteration(NULL, TRUE);

	gtk_window_destroy(GTK_WINDOW(window));
	g_object_unref(session);
	printf("smoke: %s\n", s.status == 0 ? "OK" : "FAILED");
	return s.status;
}
