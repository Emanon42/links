DROP TABLE IF EXISTS t1;

CREATE TABLE t1 (
    id1 SERIAL NOT NULL,
    id2 INT NOT NULL,
    PRIMARY KEY (id1)
);

DROP TABLE IF EXISTS t2;

CREATE TABLE t2 (
    id2 SERIAL NOT NULL,
    val VARCHAR(50) NOT NULL,
    PRIMARY KEY (id2)
);