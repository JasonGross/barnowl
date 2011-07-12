#include "owl.h"
#include <stdio.h>

typedef struct _owl_log_entry { /* noproto */
  char *filename;
  char *message;
} owl_log_entry;


static GMainContext *log_context;
static GMainLoop *log_loop;
static GThread *logging_thread;

/* This is now the one function that should be called to log a
 * message.  It will do all the work necessary by calling the other
 * functions in this file as necessary.
 */
void owl_log_message(const owl_message *m) {
  owl_function_debugmsg("owl_log_message: entering");

  if (m == NULL) {
    owl_function_debugmsg("owl_log_message: passed null message");
    return;
  }

  g_free(owl_perlconfig_call_with_message("BarnOwl::Logging::log", m));

  owl_function_debugmsg("owl_log_message: leaving");
}

static void owl_log_error_main_thread(gpointer data)
{
  owl_function_error("%s", (const char*)data);
}

static void owl_log_error(const char *message)
{
  char *data = g_strdup(message);
  owl_select_post_task(owl_log_error_main_thread,
		       data, g_free, g_main_context_default());
}

static void owl_log_write_entry(gpointer data)
{
  owl_log_entry *msg = (owl_log_entry*)data;
  FILE *file = NULL;
  file = fopen(msg->filename, "a");
  if (!file) {
    owl_log_error("Unable to open file for logging");
    return;
  }
  fprintf(file, "%s", msg->message);
  fclose(file);
}

static void owl_log_entry_free(void *data)
{
  owl_log_entry *msg = (owl_log_entry*)data;
  if (msg) {
    g_free(msg->message);
    g_free(msg->filename);
    g_free(msg);
  }
}

void owl_log_enqueue_message(const char *buffer, const char *filename)
{
  owl_log_entry *log_msg = NULL; 
  log_msg = g_new(owl_log_entry,1);
  log_msg->message = g_strdup(buffer);
  log_msg->filename = g_strdup(filename);
  owl_select_post_task(owl_log_write_entry, log_msg, 
		       owl_log_entry_free, log_context);
}

void owl_log_outgoing_zephyr_error(const owl_zwrite *zw, const char *text)
{
  owl_message *m = g_new(owl_message, 1);
  /* recip_index = 0 because there can only be one recipient anyway */
  owl_message_create_from_zwrite(m, zw, text, 0);
  g_free(owl_perlconfig_call_with_message("BarnOwl::Logging::log_outgoing_error", m));
  owl_message_delete(m);
}

static gpointer owl_log_thread_func(gpointer data)
{
  log_loop = g_main_loop_new(log_context, FALSE);
  g_main_loop_run(log_loop);
  return NULL;
}

void owl_log_init(void) 
{
  log_context = g_main_context_new();
#if GLIB_CHECK_VERSION(2, 31, 0)
  logging_thread = g_thread_new("logging",
				owl_log_thread_func,
				NULL);
#else
  GError *error = NULL;
  logging_thread = g_thread_create(owl_log_thread_func,
                                   NULL,
                                   TRUE,
                                   &error);
  if (error) {
    endwin();
    fprintf(stderr, "Error spawning logging thread: %s\n", error->message);
    fflush(stderr);
    exit(1);
  }
#endif
  
}

static void owl_log_quit_func(gpointer data)
{
  g_main_loop_quit(log_loop);
}

void owl_log_shutdown(void)
{
  owl_select_post_task(owl_log_quit_func, NULL,
		       NULL, log_context);
  g_thread_join(logging_thread);
}
