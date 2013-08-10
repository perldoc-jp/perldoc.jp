create table func (
    name varchar(255) not null primary key,
    version varchar(255) not null,
    html text
);

create table var (
    name varchar(255) not null primary key,
    version varchar(255) not null,
    html text
);

create table operator (
    name varchar(255) not null primary key,
    version varchar(255) not null,
    html text
);

create table pod (
        package     varchar(255) not null,
        description varchar(255),
        path        varchar(255) not null PRIMARY KEY,
        distvname   varchar(255) not null,
        repository  varchar(255) not null,
        html        text
);
CREAte INDEX if not exists package on pod (package);
CREAte INDEX if not exists distvname on pod (distvname);

create table heavy_diff (
        id INTEGER PRIMARY KEY,
        origin      varchar(255),
        target      varchar(255),
	is_cached   bool,
        time        integer,
        diff        text
);

CREAte INDEX if not exists heavy_diff_origin    on heavy_diff (origin);
CREAte INDEX if not exists heavy_diff_target    on heavy_diff (target);
CREAte INDEX if not exists heavy_diff_is_cached on heavy_diff (is_cached);

