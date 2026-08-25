#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *lt_session_t;
typedef int64_t lt_torrent_id;
typedef int64_t lt_stream_id;

typedef struct {
    lt_torrent_id id;
    char name[512];
    char save_path[1024];
    char error_msg[256];
    int32_t state;
    float progress;
    int32_t download_rate;
    int32_t upload_rate;
    int64_t total_done;
    int64_t total_wanted;
    int64_t total_uploaded;
    int32_t num_peers;
    int32_t num_seeds;
    int32_t num_pieces;
    int32_t pieces_done;
    int32_t is_paused;
    int32_t is_finished;
    int32_t has_metadata;
    int32_t queue_position;
} lt_torrent_status;

typedef struct {
    lt_stream_id id;
    lt_torrent_id torrent_id;
    int32_t file_index;
    char url[256];
    int64_t file_size;
    int64_t read_head;
    int32_t stream_state;
    float buffer_seconds;
    int32_t buffer_pieces;
    int32_t readahead_window;
    int32_t active_peers;
    int32_t download_rate;
} lt_stream_status;

lt_session_t lt_create_session(const char *listen_interface, int download_limit, int upload_limit);
void lt_destroy_session(lt_session_t session);
lt_torrent_id lt_add_magnet(lt_session_t session, const char *magnet_uri, const char *save_path, int stream_only);
void lt_remove_torrent(lt_session_t session, lt_torrent_id id, int delete_files);
int lt_get_status(lt_session_t session, lt_torrent_id id, lt_torrent_status *out);
lt_stream_id lt_start_stream(lt_session_t session, lt_torrent_id torrent_id, int file_index, int64_t max_cache_bytes);
void lt_stop_stream(lt_session_t session, lt_stream_id id);
int lt_get_stream_status(lt_session_t session, lt_stream_id id, lt_stream_status *out);
int lt_preload_stream(lt_session_t session, lt_stream_id id, int64_t preload_bytes);
const char *lt_last_error(void);

#ifdef __cplusplus
}
#endif
