import os
import json
import urllib.parse
import requests

# Считываем секреты из окружения
GIST_TOKEN = os.environ.get('GIST_TOKEN')
MASTER_GIST_ID = os.environ.get('MASTER_GIST_ID')
CONNECTIONS_GIST_ID = os.environ.get('CONNECTIONS_GIST_ID') # <-- Изменили переменную

HEADERS = {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {GIST_TOKEN}",
    "X-GitHub-Api-Version": "2022-11-28"
}

def main():
    # 1. Читаем ваш прикрепленный темплейт
    with open('config.template.json', 'r', encoding='utf-8') as f:
        template_str = f.read()

    # 2. Скачиваем список ссылок из Секретного Gist
    try:
        conn_gist_url = f"https://api.github.com/gists/{CONNECTIONS_GIST_ID}"
        conn_response = requests.get(conn_gist_url, headers=HEADERS)
        conn_response.raise_for_status()

        # Получаем содержимое файла (предполагаем, что он там один, или берем конкретный)
        files = conn_response.json().get('files', {})
        # Берем содержимое первого попавшегося файла в гисте
        first_file_key = list(files.keys())[0] 
        vless_links_raw = files[first_file_key]['content']
        vless_links = json.loads(vless_links_raw)

    except Exception as e:
        print(f"Ошибка при получении или парсинге списка ссылок из Gist: {e}")
        return

  # 3. Получаем текущее состояние Мастер-гиста (configs.json)
    master_gist_url = f"https://api.github.com/gists/{MASTER_GIST_ID}"
    response = requests.get(master_gist_url, headers=HEADERS)
    response.raise_for_status()
    master_files = response.json().get('files', {})
    
    configs_map = {}
    if 'configs.json' in master_files:
        try:
            configs_map = json.loads(master_files['configs.json']['content'])
        except json.JSONDecodeError:
            print("Мастер-гист пуст или содержит невалидный JSON, начинаем с чистого листа.")

    # 4. Обрабатываем каждую VLESS ссылку
    for link in vless_links:
        if not link.startswith("vless://"):
            continue
            
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        
        # Извлекаем компоненты ссылки
        uuid = parsed.username
        server_ip = parsed.hostname
        name = urllib.parse.unquote(parsed.fragment)
        
        # Параметры Reality
        sni = params.get('sni', [''])[0]
        pbk = params.get('pbk', [''])[0]
        sid = params.get('sid', [''])[0]

        if not name:
            name = f"Unnamed_VLESS_{server_ip}"

        # 5. Подставляем значения в плейсхолдеры из вашего шаблона
        config_content = template_str.replace('${VLESS_UUID}', str(uuid)) \
                                     .replace('${SERVER_IP}', str(server_ip)) \
                                     .replace('${SERVER_SNI}', str(sni)) \
                                     .replace('${PUBLIC_KEY}', str(pbk)) \
                                     .replace('${SHORT_ID}', str(sid))

        gist_payload = {
            "description": f"Sing-box VLESS Config: {name}",
            "public": False,
            "files": {
                f"{name}.json": {
                    "content": config_content
                }
            }
        }

        # 6. Создаем или обновляем Gist
        if name in configs_map and 'gist_id' in configs_map[name]:
            # Обновление существующего Gist
            gist_id = configs_map[name]['gist_id']
            print(f"Обновление Gist для '{name}'...")
            update_resp = requests.patch(f"https://api.github.com/gists/{gist_id}", headers=HEADERS, json=gist_payload)
            update_resp.raise_for_status()
        else:
            # Создание нового Gist
            print(f"Создание нового Gist для '{name}'...")
            create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=gist_payload)
            create_resp.raise_for_status()
            new_gist = create_resp.json()
            
            # Сохраняем ссылки для мастера
            configs_map[name] = {
                "name": name,
                "gist_url": new_gist['html_url'],
                "raw_url": new_gist['files'][f'{name}.json']['raw_url'],
                "gist_id": new_gist['id']
            }

    # 7. Записываем обновленный список ссылок обратно в Мастер-гист
    print("Сохранение списка конфигураций в configs.json...")
    master_payload = {
        "files": {
            "configs.json": {
                "content": json.dumps(configs_map, indent=4, ensure_ascii=False)
            }
        }
    }
    requests.patch(master_gist_url, headers=HEADERS, json=master_payload).raise_for_status()
    print("Успешно завершено!")

if __name__ == "__main__":
    main()
