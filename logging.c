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

  /* should we be logging this message? */
  if (!owl_log_shouldlog_message(m)) {
    owl_function_debugmsg("owl_log_message: not logging message");
    return;
  }

  owl_log_perl(m);

  owl_function_debugmsg("owl_log_message: leaving");
}

/* Return 1 if we should log the given message, otherwise return 0 */
int owl_log_shouldlog_message(const owl_message *m) {
  const owl_filter *f;

  /* If there's a logfilter and this message matches it, log */
  f=owl_global_get_filter(&g, owl_global_get_logfilter(&g));
  if (f && owl_filter_message_match(f, m)) return(1);

  /* otherwise we do things based on the logging variables */

  /* skip login/logout messages if appropriate */
  if (!owl_global_is_loglogins(&g) && owl_message_is_loginout(m)) return(0);
      
  /* check direction */
  if ((owl_global_get_loggingdirection(&g)==OWL_LOGGING_DIRECTION_IN) && owl_message_is_direction_out(m)) {
    return(0);
  }
  if ((owl_global_get_loggingdirection(&g)==OWL_LOGGING_DIRECTION_OUT) && owl_message_is_direction_in(m)) {
    return(0);
  }

  if (owl_message_is_type_zephyr(m)) {
    if (owl_message_is_personal(m) && !owl_global_is_logging(&g)) return(0);
    if (!owl_message_is_personal(m) && !owl_global_is_classlogging(&g)) return(0);
  } else {
    if (owl_message_is_private(m) || owl_message_is_loginout(m)) {
      if (!owl_global_is_logging(&g)) return(0);
    } else {
      if (!owl_global_is_classlogging(&g)) return(0);
    }
  }
  return(1);
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

void owl_log_append(const owl_message *m, const char *filename) {
  char *buffer = owl_perlconfig_message_call_method(m, "log", 0, NULL);
  owl_log_enqueue_message(buffer, filename);
  g_free(buffer);
}

void owl_log_outgoing_zephyr_error(const owl_zwrite *zw, const char *text)
{
  char *filename, *logpath;
  char *tobuff, *recip;
  owl_message *m;
  GString *msgbuf;
  /* create a present message so we can pass it to
   * owl_log_shouldlog_message(void)
   */
  m = g_new(owl_message, 1);
  /* recip_index = 0 because there can only be one recipient anyway */
  owl_message_create_from_zwrite(m, zw, text, 0);
  if (!owl_log_shouldlog_message(m)) {
    owl_message_delete(m);
    return;
  }
  owl_message_delete(m);

  /* chop off a local realm */
  recip = owl_zwrite_get_recip_n_with_realm(zw, 0);
  tobuff = short_zuser(recip);
  g_free(recip);

  /* expand ~ in path names */
  logpath = owl_util_makepath(owl_global_get_logpath(&g));
  filename = g_build_filename(logpath, tobuff, NULL);
  msgbuf = g_string_new("");
  g_string_printf(msgbuf, "ERROR (owl): %s\n%s\n", tobuff, text);
  if (text[strlen(text)-1] != '\n') {
    g_string_append_printf(msgbuf, "\n");
  }
  owl_log_enqueue_message(msgbuf->str, filename);
  g_string_free(msgbuf, TRUE);

  filename = g_build_filename(logpath, "all", NULL);
  g_free(logpath);
  msgbuf = g_string_new("");
  g_string_printf(msgbuf, "ERROR (owl): %s\n%s\n", tobuff, text);
  if (text[strlen(text)-1] != '\n') {
    g_string_append_printf(msgbuf, "\n");
  }
  owl_log_enqueue_message(msgbuf->str, filename);
  g_string_free(msgbuf, TRUE);

  g_free(tobuff);
}

void owl_log_perl(const owl_message *m)
{
  char *filenames_string = owl_perlconfig_call_with_message("BarnOwl::Logging::get_filenames_as_string", m);
  char **filenames = g_strsplit(filenames_string, "\n", 0);
  char **filename_ptr;
  g_free(filenames_string);

  for (filename_ptr = filenames; *filename_ptr != NULL; filename_ptr++) {
    owl_log_append(m, *filename_ptr);
  }

  g_strfreev(filenames);
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
