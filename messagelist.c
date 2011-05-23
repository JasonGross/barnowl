#include "owl.h"
#include <stdlib.h>
#include <string.h>

int owl_messagelist_create(owl_messagelist *ml)
{
  owl_list_create(&(ml->list));
  return(0);
}

int owl_messagelist_get_size(const owl_messagelist *ml)
{
  return(owl_list_get_size(&(ml->list)));
}

void *owl_messagelist_get_element(const owl_messagelist *ml, int n)
{
  return(owl_list_get_element(&(ml->list), n));
}

int owl_messagelist_get_index_by_id(const owl_messagelist *ml, int target_id)
{
  /* return the message index with id == 'id'.  If it doesn't exist return -1. */
  int first, last, mid, msg_id;
  owl_message *m;

  first = 0;
  last = owl_list_get_size(&(ml->list)) - 1;
  while (first <= last) {
    mid = (first + last) / 2;
    m = owl_list_get_element(&(ml->list), mid);
    msg_id = owl_message_get_id(m);
    if (msg_id == target_id) {
      return mid;
    } else if (msg_id < target_id) {
      first = mid + 1;
    } else {
      last = mid - 1;
    }
  }
  return -1;
}

owl_message *owl_messagelist_get_by_id(const owl_messagelist *ml, int target_id)
{
  /* return the message with id == 'id'.  If it doesn't exist return NULL. */
  int n = owl_messagelist_get_index_by_id(ml, target_id);
  if (n < 0) return NULL;
  return owl_list_get_element(&(ml->list), n);
}

int owl_messagelist_append_element(owl_messagelist *ml, void *element)
{
  return(owl_list_append_element(&(ml->list), element));
}

/* do we really still want this? */
int owl_messagelist_delete_element(owl_messagelist *ml, int n)
{
  /* mark a message as deleted */
  owl_message_mark_delete(owl_list_get_element(&(ml->list), n));
  return(0);
}

int owl_messagelist_undelete_element(owl_messagelist *ml, int n)
{
  /* mark a message as deleted */
  owl_message_unmark_delete(owl_list_get_element(&(ml->list), n));
  return(0);
}

int owl_messagelist_delete_and_expunge_element(owl_messagelist *ml, int n)
{
  return owl_list_remove_element(&(ml->list), n);
}

int owl_messagelist_expunge(owl_messagelist *ml)
{
  /* expunge deleted messages */
  int i, j;
  owl_list newlist;
  owl_message *m;

  owl_list_create(&newlist);
  /*create a new list without messages marked as deleted */
  j=owl_list_get_size(&(ml->list));
  for (i=0; i<j; i++) {
    m=owl_list_get_element(&(ml->list), i);
    if (owl_message_is_delete(m)) {
      owl_message_delete(m);
    } else {
      owl_list_append_element(&newlist, m);
    }
  }

  /* free the old list */
  owl_list_cleanup(&(ml->list), NULL);

  /* copy the new list to the old list */
  ml->list = newlist;

  return(0);
}

void owl_messagelist_invalidate_formats(const owl_messagelist *ml)
{
  int i, j;
  owl_message *m;

  j=owl_list_get_size(&(ml->list));
  for (i=0; i<j; i++) {
    m=owl_list_get_element(&(ml->list), i);
    owl_message_invalidate_format(m);
  }
}
