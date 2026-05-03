-- ---------------------------------------------------------
-- WARNING:
-- This script is for INITIALIZATION ONLY.
-- It resets TAB group data for the _DEFAULT_ group.
-- ---------------------------------------------------------

-- Start a transaction to ensure data integrity
START TRANSACTION;

-- ---------------------------------------------------------
-- TAB groups (reset + insert for idempotency)
-- ---------------------------------------------------------

DELETE
FROM msdgl.tab_groups
WHERE `group` = '_DEFAULT_'
  AND `world` IS NULL
  AND `server` IS NULL
  AND `property` IN ('tabprefix', 'tagprefix', 'customtabname', 'tabsuffix', 'tagsuffix');

INSERT INTO msdgl.tab_groups (`group`,
                              `property`,
                              `value`,
                              `world`,
                              `server`)
VALUES ('_DEFAULT_',
        'tabprefix',
        '%luckperms-prefix%',
        NULL,
        NULL),
       ('_DEFAULT_',
        'tagprefix',
        '%luckperms-prefix%',
        NULL,
        NULL),
       ('_DEFAULT_',
        'customtabname',
        '%displayname%',
        NULL,
        NULL),
       ('_DEFAULT_',
        'tabsuffix',
        '%luckperms-suffix%',
        NULL,
        NULL),
       ('_DEFAULT_',
        'tagsuffix',
        '%luckperms-suffix%',
        NULL,
        NULL);

-- Finalize the transaction
COMMIT;
