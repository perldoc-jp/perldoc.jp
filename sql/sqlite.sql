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
-- SELECT 対象の列をすべてキーに含めた covering index にしている。
-- メタデータ系クエリ (一覧・バージョン解決) が巨大な html 列を持つ
-- テーブル本体に触れずインデックスだけで完結する。
CREAte INDEX if not exists pod_package_cover   on pod (package, distvname, path, description);
CREAte INDEX if not exists pod_distvname_cover on pod (distvname, package, path, description);
-- path への後方一致 LIKE (get_latest の '%/Foo.pod' 等) をテーブル全走査でなく
-- インデックス全走査で済ませるための index
CREAte INDEX if not exists pod_path_cover      on pod (path, package, distvname);
