-- TABLES CREATION

CREATE SCHEMA IF NOT EXISTS music_store;

-- 1. Таблица категорий
CREATE TABLE music_store.categories (
    category_id SERIAL PRIMARY KEY,
    category_name VARCHAR(100) NOT NULL,
    description TEXT
);

-- 2. Таблица поставщиков
CREATE TABLE music_store.suppliers (
    supplier_id SERIAL PRIMARY KEY,
    supplier_name VARCHAR(150) NOT NULL,
    contact_email VARCHAR(255),
    phone VARCHAR(20)
);

-- 3. Таблица клиентов
CREATE TABLE music_store.customers (
    customer_id SERIAL PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL UNIQUE,
    phone VARCHAR(20),
    registration_date DATE DEFAULT CURRENT_DATE
);

-- 4. Таблица товаров (SCD2)
CREATE TABLE music_store.products (
    product_key SERIAL PRIMARY KEY, -- Суррогатный ключ версии
    product_id INT NOT NULL, -- Неизменный бизнес-код товара
    category_id INT NOT NULL REFERENCES music_store.categories(category_id),
    supplier_id INT NOT NULL REFERENCES music_store.suppliers(supplier_id),
    product_name VARCHAR(255) NOT NULL,
    cost_price NUMERIC(10, 2) NOT NULL CHECK (cost_price >= 0),
    retail_price NUMERIC(10, 2) NOT NULL CHECK (retail_price >= 0),
    start_dttm TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    end_dttm TIMESTAMP NOT NULL DEFAULT '2999-12-31 23:59:59',
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

-- 5. Таблица заказов
CREATE TABLE music_store.orders (
    order_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES music_store.customers(customer_id),
    order_date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status VARCHAR(50) NOT NULL DEFAULT 'New'
);

-- 6. Позиции заказов (строки чека)
CREATE TABLE music_store.order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id INT NOT NULL REFERENCES music_store.orders(order_id) ON DELETE CASCADE,
    product_key INT NOT NULL REFERENCES music_store.products(product_key), -- Связь с конкретной версией товара
    quantity INT NOT NULL CHECK (quantity > 0),
    price_at_purchase NUMERIC(10, 2) NOT NULL CHECK (price_at_purchase >= 0)
);

-- накатим индексы на таблицы

-- Создаем индекс для быстрого поиска только актуальных ценников
CREATE INDEX idx_products_active ON music_store.products(product_id) WHERE is_active = TRUE;

-- Индексы для таблиц order_items / orders (нужны для быстрого выполнения аналитических запросов, так как таблица order_items содержит порядка ~12к строк)
CREATE INDEX idx_order_items_product_key ON music_store.order_items(product_key);

CREATE INDEX idx_orders_customer_id ON music_store.orders(customer_id);


-- TRIGGER CREATION

CREATE OR REPLACE FUNCTION music_store.fn_validate_customer_data()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.email NOT LIKE '%@%.%' THEN -- чекаем что в имейле есть собачка / точка
        RAISE EXCEPTION 'Ошибка: поломаный email %', NEW.email;
    END IF;

    IF NEW.phone ~ '[a-zA-Z]' THEN -- чекаем что в номере телефона нет букв
        RAISE EXCEPTION 'Ошибка: в номере телефона "%" есть буквы ', NEW.phone;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_before_insert_customer
BEFORE INSERT ON music_store.customers
FOR EACH ROW
EXECUTE FUNCTION music_store.fn_validate_customer_data();

-- FYI: для импорта я использовал возможности DBEAVER: импортировал csv-файл в таблицу (P.S импорт products.csv осуществлялся во временную таблицу, и уже потом через процедуру данные перекидывались в таблицу products)
-- ВРЕМЕННАЯ ТАБЛИЦА ЧЕРЕЗ КОТОРУЮ ПОТОМ С ПОМОЩЬЮ ПРОЦЕДУРЫ ИНФА БУДЕТ ЛИТЬСЯ В SCD2 ТАБЛУ products (через процедуру)  

CREATE TABLE music_store.stg_products (
    product_id INT,
    category_id INT,
    supplier_id INT,
    product_name VARCHAR(255),
    cost_price NUMERIC(10,2),
    retail_price NUMERIC(10,2)
);

-- ПРОЦЕДУРА ДЛЯ ПРОКИДЫВАНИЯ ИНФЫ В ТАБЛИЦУ с SCD2 products

-- 5 Процедура загрузчик для добавления новых записей в таблицу music_stope.products

CREATE OR REPLACE PROCEDURE music_store.load_products_scd2()
LANGUAGE plpgsql
AS $$
BEGIN
    -- cначала закрываем версии для тех товаров, у которых изменились атрибуты
    WITH updated_info AS (
        SELECT s.product_id
        FROM music_store.stg_products s
        JOIN music_store.products p ON s.product_id = p.product_id
        WHERE p.is_active = TRUE 
          AND (p.retail_price != s.retail_price OR p.product_name != s.product_name)
    )
    UPDATE music_store.products
    SET end_dttm = CURRENT_TIMESTAMP,
        is_active = FALSE
    WHERE product_id IN (SELECT product_id FROM updated_info)
      AND is_active = TRUE;

    -- вставляем новые записи
    INSERT INTO music_store.products (
        product_id, category_id, supplier_id, product_name, 
        cost_price, retail_price, start_dttm, end_dttm, is_active
    )
    SELECT 
        s.product_id, s.category_id, s.supplier_id, s.product_name, 
        s.cost_price, s.retail_price, CURRENT_TIMESTAMP, '2999-12-31 23:59:59', TRUE
    FROM music_store.stg_products s
    LEFT JOIN music_store.products p 
        ON s.product_id = p.product_id AND p.is_active = TRUE
    WHERE p.product_id IS NULL
        AND s.cost_price > 0
        AND s.retail_price > 0;

    -- Очищаем временную таблц после успешной обработки
    TRUNCATE TABLE music_store.stg_products;

    COMMIT;
END;
$$;

-- ВЫЗОВ ЭТОЙ ПРОЦЕДУРЫ (ДЕЛАТЬ ПОСЛЕ ЗАЛИВА ДАННЫХ ВО ВРЕМЕННУЮ ТАБЛИЦУ music_store.stg_products)

CALL music_store.load_products_scd2();

-- INSERTы в таблицу products через временную таблицу и в дальнейшем вызов процедуры для переноса в таблицу products

SELECT * FROM music_store.products;

INSERT INTO music_store.stg_products (product_id, category_id, supplier_id, product_name, cost_price, retail_price)
VALUES 
-- 1. Изменяем цену для существующего товара (ID 1)
(1, 2, 1, 'Студийный Усилитель Передо', 91831.72, 120990.00), 

-- 2. Добавляем новый товар, которого еще нет в базе (ID 999)
(999, 2, 1, 'Барабанные палочки Pro-Mark-Ultra', 500.00, 1100.00);

CALL music_store.load_products_scd2();


INSERT INTO music_store.stg_products (product_id, category_id, supplier_id, product_name, cost_price, retail_price)
VALUES 
-- 1. Изменяем цену для существующего товара (ID 1)
(1, 2, 1, 'Студийный Усилитель Передо', 91831.72, 110990.00), 

-- 2. Добавляем новый товар, которого еще нет в базе (ID 999)
(666, 2, 1, 'Укулеле Pro-Mark-Ultra', 10000.00, 19000.00);

CALL music_store.load_products_scd2();


SELECT
    *
FROM music_store.products;


-- АНАЛИТИЧЕСКИЙ ЗАПРОС (EXPLAIN ANALYZE раскоментить/закоментить в зависимости от того, нужен ли план запроса или его результат)
-- FYI: аналитический запрос ранжирует магазины по категории (от самых больших по выручке к наименьшим)
-- А также внутри каждой категории считает какой процент от общей выручки внутри категории принес конкретный товар

-- EXPLAIN ANALYZE
WITH product_revenue AS (
    -- считаем чистую выручку по товарам
    SELECT 
        c.category_name,
        p.product_name,
        SUM(oi.quantity * oi.price_at_purchase) AS revenue
    FROM music_store.order_items oi
    JOIN music_store.products p ON oi.product_key = p.product_key
    JOIN music_store.categories c ON p.category_id = c.category_id
    GROUP BY c.category_name, p.product_name
),
category_totals AS (
    -- считаем выручку по категориям отдельно
    SELECT 
        category_name,
        product_name,
        revenue,
        SUM(revenue) OVER(PARTITION BY category_name) AS cat_total_revenue
    FROM product_revenue
)
-- финальный расчет долей и ранжирование
SELECT 
    category_name,
    product_name,
    revenue,
    ROUND(revenue * 100.0 / cat_total_revenue, 2) AS share_in_cat_pct,
    DENSE_RANK() OVER(ORDER BY cat_total_revenue DESC) AS cat_rank
FROM category_totals
ORDER BY cat_rank, revenue DESC;



-- SELECT-запросы на таблы

SELECT
    *
FROM music_store.categories;

SELECT
    *
FROM music_store.suppliers;


SELECT
    *
FROM music_store.customers;

SELECT
    *
FROM music_store.orders;

SELECT
    *
FROM music_store.order_items;

SELECT
    *
FROM music_store.products;
