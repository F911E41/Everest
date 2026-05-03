CREATE TABLE IF NOT EXISTS msdgl.luckperms_group_permissions
(
    `id`         int(11)      NOT NULL AUTO_INCREMENT,
    `name`       varchar(36)  NOT NULL,
    `permission` varchar(200) NOT NULL,
    `value`      tinyint(1)   NOT NULL,
    `server`     varchar(36)  NOT NULL,
    `world`      varchar(64)  NOT NULL,
    `expiry`     bigint(20)   NOT NULL,
    `contexts`   varchar(200) NOT NULL,
    PRIMARY KEY (`id`),
    KEY `luckperms_group_permissions_name` (`name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_uca1400_ai_ci;

CREATE TABLE IF NOT EXISTS msdgl.luckperms_groups
(
    `name` varchar(36) NOT NULL,
    PRIMARY KEY (`name`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_uca1400_ai_ci;

CREATE TABLE IF NOT EXISTS msdgl.tab_groups
(
    `group`    varchar(64)   DEFAULT NULL,
    `property` varchar(16)   DEFAULT NULL,
    `value`    varchar(1024) DEFAULT NULL,
    `world`    varchar(64)   DEFAULT NULL,
    `server`   varchar(64)   DEFAULT NULL
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
