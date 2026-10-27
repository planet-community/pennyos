// SPDX-License-Identifier: GPL-2.0
/*
 * penny-splash: the PennyOS animation shown while the desktop starts.
 *
 * A little book computer opens, its screen lights up with a blinking cursor, the
 * "PennyOS" wordmark types itself out, then the whole thing fades away to reveal
 * the desktop that was loading behind it. About 2.6 s; a tap skips it.
 *
 * It is a layer-shell surface with no window-management animation of its own,
 * drawn with cairo/pango as vectors, so it is sharp at any scale and the
 * compositor handles the panel rotation. The clock starts at the first frame
 * the compositor actually shows, not at launch: on the phone that can be seconds.
 *
 *   penny-splash                          over the desktop while it starts (overlay
 *                                         layer), fades out at the end
 *   penny-splash --greeter                on the login screen: below the login box
 *                                         (bottom layer), keeps the finished logo
 *                                         until the login box covers it
 *   penny-splash --render DIR W H FPS     write the frames as PNGs, for previews
 *
 * Build: tools/splash/build.sh (GTK 3 + gtk-layer-shell).
 */
#include <gtk/gtk.h>
#include <gtk-layer-shell.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define DURATION 2.6

/* Tokyo Night, the same palette as the rest of the desktop */
#define BG       0x16, 0x16, 0x1e
#define SURFACE  0x24, 0x28, 0x3b
#define EDGE     0x41, 0x48, 0x68
#define BLUE     0x7a, 0xa2, 0xf7
#define CYAN     0x7d, 0xcf, 0xff
#define FG       0xc0, 0xca, 0xf5
#define ORANGE   0xff, 0x9e, 0x64

static void rgba(cairo_t *cr, int r, int g, int b, double a)
{
	cairo_set_source_rgba(cr, r / 255.0, g / 255.0, b / 255.0, a);
}

static double clamp01(double x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
/* progress of t through [t0, t1], 0..1 */
static double span(double t, double t0, double t1) { return clamp01((t - t0) / (t1 - t0)); }
static double ease_out(double x) { return 1 - pow(1 - x, 3); }
static double ease_in_out(double x) { return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2; }

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r)
{
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(cr);
}

/* one frame at time t (seconds) on a w x h canvas */
static gboolean greeter;

static void draw(cairo_t *cr, double w, double h, double t)
{
	/* the login screen keeps the finished logo: stop just before the fade */
	if (greeter && t > 2.0)
		t = 2.0;
	double fade = 1 - ease_in_out(span(t, 2.05, DURATION));
	double u = fmin(w, h) / 100.0;        /* layout unit */
	double cx = w / 2, cy = h / 2 - 9 * u;

	cairo_save(cr);
	cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
	rgba(cr, BG, fade);
	cairo_paint(cr);
	cairo_restore(cr);
	if (fade <= 0)
		return;
	cairo_push_group(cr);

	/* ---- the book computer: base on the table, lid hinged at its back edge ---- */
	double appear = ease_out(span(t, 0.0, 0.35));
	double open = ease_in_out(span(t, 0.15, 1.05));      /* 0 closed .. 1 open */
	double bw = 44 * u, bh = 4.2 * u;               /* base, as wide as the Cosmo */
	double by = cy + 14 * u + (1 - appear) * 4 * u; /* base top edge */
	double lid_h = 22 * u;                         /* screen about 2:1, like the Cosmo */
	double ang = open * 0.58 * M_PI;                /* lid angle from closed, up to ~105 deg */
	double lid_vis = lid_h * sin(ang);              /* projected height */
	double lid_w = bw * (0.94 + 0.06 * cos(ang));   /* slight foreshortening at the top */

	cairo_save(cr);
	cairo_push_group(cr);
	/* soft shadow */
	cairo_save(cr);
	cairo_translate(cr, cx, by + bh + 1.2 * u);
	cairo_scale(cr, bw * 0.62, 1.6 * u);
	cairo_arc(cr, 0, 0, 1, 0, 2 * M_PI);
	cairo_restore(cr);
	rgba(cr, 0, 0, 0, 0.35);
	cairo_fill(cr);
	/* base */
	rounded_rect(cr, cx - bw / 2, by, bw, bh, 1.4 * u);
	rgba(cr, SURFACE, 1);
	cairo_fill_preserve(cr);
	rgba(cr, EDGE, 1);
	cairo_set_line_width(cr, 0.45 * u);
	cairo_stroke(cr);
	/* keyboard: three rows of keys on the base's top face */
	for (int row = 0; row < 3; row++)
		for (int k = 0; k < 11; k++) {
			double kw = bw * 0.072, kx = cx - bw * 0.43 + k * bw * 0.079 + (row == 1) * bw * 0.02;
			rounded_rect(cr, kx, by + 0.6 * u + row * 1.15 * u, kw, 0.75 * u, 0.25 * u);
			rgba(cr, EDGE, 0.9);
			cairo_fill(cr);
		}
	/* lid: from the hinge up, outside shell first, then the screen inside it */
	if (lid_vis > 0.3 * u) {
		double lx = cx - lid_w / 2, ly = by - lid_vis;
		rounded_rect(cr, lx, ly, lid_w, lid_vis + 0.6 * u, 1.6 * u);
		rgba(cr, SURFACE, 1);
		cairo_fill_preserve(cr);
		rgba(cr, EDGE, 1);
		cairo_set_line_width(cr, 0.45 * u);
		cairo_stroke(cr);
		double m = 1.6 * u;
		if (lid_vis > 2.5 * m) {
			double sx = lx + m, sy = ly + m, sw = lid_w - 2 * m, sh = lid_vis - 1.6 * m;
			double glow = ease_out(span(t, 0.75, 1.15));
			rounded_rect(cr, sx, sy, sw, sh, 0.8 * u);
			rgba(cr, BG, 1);
			cairo_fill_preserve(cr);
			/* the screen lights up: a blue wash from the centre */
			cairo_pattern_t *p = cairo_pattern_create_radial(sx + sw / 2, sy + sh / 2, 0,
									 sx + sw / 2, sy + sh / 2, sw * 0.7);
			cairo_pattern_add_color_stop_rgba(p, 0, 0x7a / 255.0, 0xa2 / 255.0, 0xf7 / 255.0, 0.32 * glow);
			cairo_pattern_add_color_stop_rgba(p, 1, 0x7a / 255.0, 0xa2 / 255.0, 0xf7 / 255.0, 0.06 * glow);
			cairo_set_source(cr, p);
			cairo_fill(cr);
			cairo_pattern_destroy(p);
			/* a prompt and a blinking cursor */
			if (glow > 0) {
				double tx = sx + 2 * u, ty = sy + sh * 0.5;
				rgba(cr, CYAN, glow);
				cairo_set_line_width(cr, 0.55 * u);
				cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
				cairo_move_to(cr, tx, ty - 1.4 * u);
				cairo_line_to(cr, tx + 1.3 * u, ty);
				cairo_line_to(cr, tx, ty + 1.4 * u);
				cairo_stroke(cr);
				if (fmod(t - 0.75, 0.5) < 0.3) {
					cairo_rectangle(cr, tx + 2.4 * u, ty - 1.5 * u, 1.3 * u, 3 * u);
					rgba(cr, FG, glow);
					cairo_fill(cr);
				}
			}
		}
	}
	cairo_pop_group_to_source(cr);
	cairo_paint_with_alpha(cr, appear);
	cairo_restore(cr);

	/* ---- the wordmark types itself out under the computer ---- */
	static const char word[] = "PennyOS";
	int n = (int)floor(span(t, 1.0, 1.55) * 7 + 0.0001);
	if (t >= 1.0) {
		PangoLayout *pl = pango_cairo_create_layout(cr);
		PangoFontDescription *fd = pango_font_description_from_string("Inter Variable Bold");
		pango_font_description_set_absolute_size(fd, 11 * u * PANGO_SCALE);
		pango_layout_set_font_description(pl, fd);
		/* lay out the whole word to centre it, then show the typed part */
		pango_layout_set_text(pl, word, -1);
		int fw, fh;
		pango_layout_get_pixel_size(pl, &fw, &fh);
		double wx = cx - fw / 2.0, wy = by + bh + 5 * u;
		char markup[256];
		char penny[8] = "", os[4] = "";
		snprintf(penny, sizeof(penny), "%.*s", n < 5 ? n : 5, word);
		if (n > 5)
			snprintf(os, sizeof(os), "%.*s", n - 5, word + 5);
		snprintf(markup, sizeof(markup),
			 "<span foreground='#c0caf5'>%s</span><span foreground='#ff9e64'>%s</span>", penny, os);
		pango_layout_set_markup(pl, markup, -1);
		cairo_move_to(cr, wx, wy);
		pango_cairo_show_layout(cr, pl);
		/* the typing cursor follows the text until the word is complete */
		if (n < 7 || fmod(t, 0.5) < 0.3) {
			int tw, th;
			pango_layout_get_pixel_size(pl, &tw, &th);
			cairo_rectangle(cr, wx + tw + 0.8 * u, wy + fh * 0.18, 0.9 * u, fh * 0.66);
			rgba(cr, BLUE, n < 7 ? 1 : 0.8);
			cairo_fill(cr);
		}
		pango_font_description_free(fd);
		g_object_unref(pl);
	}

	cairo_pop_group_to_source(cr);
	cairo_paint_with_alpha(cr, fade);
}

/* ------------------------------------------------------------- on screen -- */

static gint64 launch_us, start_us;

static gboolean on_draw(GtkWidget *wd, cairo_t *cr, gpointer data)
{
	(void)data;
	double t = start_us ? (g_get_monotonic_time() - start_us) / 1e6 : 0;
	draw(cr, gtk_widget_get_allocated_width(wd), gtk_widget_get_allocated_height(wd), t);
	return TRUE;
}

static gboolean tick(GtkWidget *wd, GdkFrameClock *clock, gpointer data)
{
	(void)clock; (void)data;
	if (!start_us) {
		start_us = g_get_monotonic_time();
		g_printerr("penny-splash: first frame %.2f s after launch\n", (start_us - launch_us) / 1e6);
	}
	double t = (g_get_monotonic_time() - start_us) / 1e6;
	if (greeter && t > 2.1)
		return G_SOURCE_REMOVE;   /* the logo is complete and stays; no more frames */
	if (t >= DURATION) {
		gtk_main_quit();
		return G_SOURCE_REMOVE;
	}
	gtk_widget_queue_draw(wd);
	return G_SOURCE_CONTINUE;
}

static gboolean skip(GtkWidget *wd, GdkEvent *ev, gpointer data)
{
	(void)wd; (void)ev; (void)data;
	gtk_main_quit();
	return TRUE;
}

/* never stay up if the compositor shows nothing, or stops showing frames */
static gboolean give_up(gpointer data)
{
	(void)data;
	gint64 now = g_get_monotonic_time();
	if (!start_us ? now - launch_us > 15000000 : (!greeter && now - start_us > (DURATION + 2) * 1e6)) {
		g_printerr("penny-splash: %s, giving up\n", start_us ? "frames stopped" : "no frame shown in 15 s");
		gtk_main_quit();
		return G_SOURCE_REMOVE;
	}
	return G_SOURCE_CONTINUE;
}

static int show(int argc, char **argv)
{
	gtk_init(&argc, &argv);
	GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_layer_init_for_window(GTK_WINDOW(win));
	gtk_layer_set_namespace(GTK_WINDOW(win), "penny-splash");
	gtk_layer_set_layer(GTK_WINDOW(win), greeter ? GTK_LAYER_SHELL_LAYER_BOTTOM : GTK_LAYER_SHELL_LAYER_OVERLAY);
	gtk_layer_set_exclusive_zone(GTK_WINDOW(win), -1);
	for (int e = 0; e < GTK_LAYER_SHELL_EDGE_ENTRY_NUMBER; e++)
		gtk_layer_set_anchor(GTK_WINDOW(win), e, TRUE);
	gtk_layer_set_keyboard_mode(GTK_WINDOW(win), GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);

	/* transparent window, so the fade at the end shows the desktop through it */
	GdkScreen *scr = gtk_widget_get_screen(win);
	GdkVisual *vis = gdk_screen_get_rgba_visual(scr);
	if (vis)
		gtk_widget_set_visual(win, vis);
	gtk_widget_set_app_paintable(win, TRUE);

	GtkWidget *area = gtk_drawing_area_new();
	gtk_container_add(GTK_CONTAINER(win), area);
	gtk_widget_add_events(area, GDK_BUTTON_PRESS_MASK | GDK_TOUCH_MASK);
	g_signal_connect(area, "draw", G_CALLBACK(on_draw), NULL);
	if (!greeter) {
		g_signal_connect(area, "button-press-event", G_CALLBACK(skip), NULL);
		g_signal_connect(area, "touch-event", G_CALLBACK(skip), NULL);
	}
	gtk_widget_add_tick_callback(area, tick, NULL, NULL);
	g_timeout_add(500, give_up, NULL);

	gtk_widget_show_all(win);
	gtk_main();
	return 0;
}

/* --------------------------------------------------------------- preview -- */

static int render(const char *dir, int w, int h, int fps)
{
	int frames = (int)ceil(DURATION * fps) + 1;
	for (int i = 0; i < frames; i++) {
		cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
		cairo_t *cr = cairo_create(s);
		draw(cr, w, h, i / (double)fps);
		char path[4096];
		snprintf(path, sizeof(path), "%s/frame%03d.png", dir, i);
		if (cairo_surface_write_to_png(s, path) != CAIRO_STATUS_SUCCESS) {
			fprintf(stderr, "cannot write %s\n", path);
			return 1;
		}
		cairo_destroy(cr);
		cairo_surface_destroy(s);
	}
	printf("%d frames in %s\n", frames, dir);
	return 0;
}

int main(int argc, char **argv)
{
	launch_us = g_get_monotonic_time();
	if (argc == 2 && g_str_equal(argv[1], "--greeter")) {
		greeter = TRUE;
		argc = 1;
	}
	if (argc == 6 && g_str_equal(argv[1], "--render"))
		return render(argv[2], atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
	return show(argc, argv);
}
