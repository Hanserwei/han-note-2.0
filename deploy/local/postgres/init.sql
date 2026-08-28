\set ON_ERROR_STOP on

-- PostgreSQL's entrypoint runs this file only when the data volume is empty.
-- Keep role/permission and channel/topic tables ahead of their seed rows.
\ir /schema/sql/t_role.sql
\ir /schema/sql/t_permission.sql
\ir /schema/sql/t_role_permission_rel.sql
\ir /schema/sql/t_user.sql
\ir /schema/sql/t_user_role_rel.sql
\ir /schema/sql/t_channel.sql
\ir /schema/sql/t_topic.sql
\ir /schema/sql/t_channel_topic_rel.sql
\ir /schema/sql/t_note.sql
\ir /schema/sql/t_note_like.sql
\ir /schema/sql/t_note_collection.sql
\ir /schema/sql/t_comment.sql
\ir /schema/sql/t_comment_like.sql
\ir /schema/sql/t_fans.sql
\ir /schema/sql/t_following.sql
\ir /schema/sql/t_user_count.sql
\ir /schema/sql/t_note_count.sql
\ir /schema/sql/t_mq_send_fail.sql
\ir /schema/sql/init_data.sql
