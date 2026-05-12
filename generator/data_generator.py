import pandas as pd
import random
from faker import Faker
from datetime import datetime, timedelta
import os

# Инициализация
fake = Faker("ru_RU")
Faker.seed(42)
random.seed(42)

# Настройки объемов данных
NUM_CUSTOMERS = 1500
NUM_PRODUCTS_BASE = 300
NUM_ORDERS = 5000

# Создаем папку data, если ее нет
os.makedirs("../data", exist_ok=True)

print("Генерация данных начата...")

# ==========================================
# 1. CATEGORIES (Категории)
# ==========================================
categories_data = [
    (1, "Струнные", "Гитары, скрипки, виолончели"),
    (2, "Клавишные", "Пианино, синтезаторы, рояли"),
    (3, "Ударные", "Барабанные установки, перкуссия"),
    (4, "Духовые", "Саксофоны, трубы, флейты"),
    (5, "Звуковое оборудование", "Микрофоны, микшеры, кабели"),
]
df_categories = pd.DataFrame(
    categories_data, columns=["category_id", "category_name", "description"]
)
df_categories.to_csv("../data/categories.csv", index=False)

# ==========================================
# 2. SUPPLIERS (Поставщики)
# ==========================================
suppliers_data = [
    (1, "Yamaha Russia", "sales@yamaha.ru", "+7-495-123-4567"),
    (2, "Fender Music", "info@fender.com", "+1-800-555-0199"),
    (3, "Roland Pro", "contact@roland.com", "+7-812-987-6543"),
    (4, "Korg Inc", "sales@korg.jp", "+81-3-1234-5678"),
    (5, "МузТорг Опт", "opt@muztorg.ru", "+7-495-000-1122"),
]
df_suppliers = pd.DataFrame(
    suppliers_data, columns=["supplier_id", "supplier_name", "contact_email", "phone"]
)
df_suppliers.to_csv("../data/suppliers.csv", index=False)

# ==========================================
# 3. CUSTOMERS (Клиенты) + Грязные данные
# ==========================================
customers = []
for i in range(1, NUM_CUSTOMERS + 1):
    # Генерируем грязные данные (примерно 2% клиентов)
    is_dirty = random.random() < 0.02

    email = fake.email()
    if is_dirty:
        email = email.replace("@", "")  # Ломаем email (убираем собачку)

    customers.append(
        {
            "customer_id": i,
            "first_name": fake.first_name(),
            "last_name": fake.last_name(),
            "email": email,
            "phone": fake.phone_number() if not is_dirty else "ERROR-PHONE",
            "registration_date": fake.date_between(start_date="-4y", end_date="today"),
        }
    )

df_customers = pd.DataFrame(customers)
df_customers.to_csv("../data/customers.csv", index=False)

# ==========================================
# 4. PRODUCTS (Товары с SCD2) + Грязные данные
# ==========================================
products = []
product_key_counter = 1

for prod_id in range(1, NUM_PRODUCTS_BASE + 1):
    cat_id = random.randint(1, 5)
    sup_id = random.randint(1, 5)

    adjectives = [
        "Профессиональный",
        "Студийный",
        "Акустический",
        "Электронный",
        "Базовый",
    ]
    nouns = ["Инструмент", "Набор", "Комплект", "Синтезатор", "Усилитель"]
    name = (
        f"{random.choice(adjectives)} {random.choice(nouns)} {fake.word().capitalize()}"
    )

    base_cost = round(random.uniform(1000, 150000), 2)
    retail_price = round(base_cost * random.uniform(1.2, 1.8), 2)  # Наценка 20-80%

    # Имитируем историчность (SCD2): у 30% товаров есть "старая" закрытая версия
    has_history = random.random() < 0.3
    if has_history:
        old_cost = round(base_cost * 0.9, 2)  # Раньше было дешевле
        old_retail = round(retail_price * 0.9, 2)
        start_dttm = fake.date_time_between(start_date="-3y", end_date="-1y")
        end_dttm = start_dttm + timedelta(days=random.randint(100, 300))

        products.append(
            {
                "product_key": product_key_counter,
                "product_id": prod_id,
                "category_id": cat_id,
                "supplier_id": sup_id,
                "product_name": name,
                "cost_price": old_cost,
                "retail_price": old_retail,
                "start_dttm": start_dttm,
                "end_dttm": end_dttm,
                "is_active": False,
            }
        )
        product_key_counter += 1
        current_start_dttm = (
            end_dttm  # Новая версия начинается тогда, когда кончилась старая
        )
    else:
        current_start_dttm = fake.date_time_between(start_date="-1y", end_date="now")

    # Текущая актуальная версия
    # Грязные данные: отрицательная цена у нескольких активных товаров
    is_dirty_price = random.random() < 0.01

    products.append(
        {
            "product_key": product_key_counter,
            "product_id": prod_id,
            "category_id": cat_id,
            "supplier_id": sup_id,
            "product_name": name,
            "cost_price": base_cost if not is_dirty_price else -500.00,
            "retail_price": retail_price if not is_dirty_price else -1000.00,
            "start_dttm": current_start_dttm,
            "end_dttm": datetime(2999, 12, 31, 23, 59, 59),
            "is_active": True,
        }
    )
    product_key_counter += 1

df_products = pd.DataFrame(products)
df_products.to_csv("../data/products.csv", index=False)

# ==========================================
# 5. ORDERS (Заказы) с Сезонностью
# ==========================================
orders = []
statuses = ["Completed", "Completed", "Completed", "Processing", "Cancelled"]


def generate_seasonal_date():
    """С вероятностью 40% дата выпадет на август или сентябрь (школьный сезон)"""
    year = random.choice([2023, 2024, 2025])
    if random.random() < 0.40:
        month = random.choice([8, 9])
    else:
        month = random.choice([1, 2, 3, 4, 5, 6, 7, 10, 11, 12])

    day = random.randint(1, 28)
    return datetime(year, month, day, random.randint(8, 22), random.randint(0, 59))


for i in range(1, NUM_ORDERS + 1):
    orders.append(
        {
            "order_id": i,
            "customer_id": random.randint(1, NUM_CUSTOMERS),
            "order_date": generate_seasonal_date(),
            "status": random.choice(statuses),
        }
    )

df_orders = pd.DataFrame(orders)
df_orders.to_csv("../data/orders.csv", index=False)

# ==========================================
# 6. ORDER_ITEMS (Позиции заказов)
# ==========================================
order_items = []
order_item_counter = 1

active_products = df_products[df_products["is_active"] == True]

for order in orders:
    # От 1 до 4 позиций в чеке
    num_items = random.randint(1, 4)

    # Выбираем случайные ключи активных товаров
    chosen_products = active_products.sample(num_items)

    for _, prod in chosen_products.iterrows():
        # Генерируем грязные данные (нулевое количество)
        qty = random.randint(1, 3)
        if random.random() < 0.005:
            qty = 0

        order_items.append(
            {
                "order_item_id": order_item_counter,
                "order_id": order["order_id"],
                "product_key": prod["product_key"],
                "quantity": qty,
                "price_at_purchase": prod["retail_price"],
            }
        )
        order_item_counter += 1

df_order_items = pd.DataFrame(order_items)
df_order_items.to_csv("../data/order_items.csv", index=False)

print(f"Готово! Сгенерировано:")
print(f"  Клиентов: {len(df_customers)}")
print(f"  Товаров (версий): {len(df_products)}")
print(f"  Заказов: {len(df_orders)}")
print(f"  Позиций в чеках: {len(df_order_items)}")
print("Файлы сохранены в папку data/")
