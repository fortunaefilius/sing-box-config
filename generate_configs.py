import os
import json
import urllib.parse
import requests

GIST_TOKEN = os.environ.get('GIST_TOKEN')
MASTER_GIST_ID = os.environ.get('MASTER_GIST_ID')
CONNECTIONS_GIST_ID = os.environ.get('CONNECTIONS_GIST_ID')

HEADERS = {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {GIST_TOKEN}",
    "X-GitHub-Api-Version": "2022-11-28"
}

def main():
    # 1. Читаем темплейт
    with open('config.template.json', 'r', encoding='utf-8') as f:
        template_str = f.read()

    # 2. Скачиваем список ссылок из Секретного Gist
    try:
        conn_gist_url = f"https://api.github.com/gists/{CONNECTIONS_GIST_ID}"
        conn_response = requests.get(conn_gist_url, headers=HEADERS)
        conn_response.raise_for_status()
        
        files = conn_response.json().get('files', {})
        first_file_key = list(files.keys())[0] 
        vless_links_raw = files[first_file_key]['content']
        vless_links = json.loads(vless_links_raw)
    except Exception as e:
        print(f"Ошибка при получении списка ссылок: {e}")
        return

    # 3. Умная обработка Мастер-гиста (configs.json)
    configs_map = {}
    master_gist_url = None
    needs_new_master = False

    if MASTER_GIST_ID:
        master_gist_url = f"https://api.github.com/gists/{MASTER_GIST_ID}"
        response = requests.get(master_gist_url, headers=HEADERS)
        
        if response.status_code == 200:
            master_files = response.json().get('files', {})
            if 'configs.json' in master_files:
                content = master_files['configs.json'].get('content', '{}')
                try:
                    parsed_content = json.loads(content)
                    if isinstance(parsed_content, dict):
                        configs_map = parsed_content
                except json.JSONDecodeError:
                    pass
        elif response.status_code == 404:
            print("Внимание: Мастер-гист по указанному ID не найден (вероятно, удален).")
            needs_new_master = True
        else:
            response.raise_for_status()
    else:
        needs_new_master = True

    # Создаем новый Мастер-гист, если ID не указан или старый удален
    if needs_new_master:
        print("Создание нового Мастер-гиста...")
        payload = {
            "description": "VLESS Master Configs Map",
            "public": False,
            "files": {"configs.json": {"content": "{}"}}
        }
        create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=payload)
        create_resp.raise_for_status()
        new_gist = create_resp.json()
        master_gist_url = new_gist['url']
        
        warning_msg = "Был создан новый Мастер-гист. В целях безопасности его ID скрыт. Пожалуйста, найдите новый Gist в своем профиле и обновите секрет MASTER_GIST_ID."
        print(f"::warning title=Требуется обновление секрета MASTER_GIST_ID::{warning_msg}")

        print("\n" + "="*50)
        print("⚠️ ВАЖНО: БЫЛ СОЗДАН НОВЫЙ МАСТЕР-ГИСТ!")
        print("Зайдите на https://gist.github.com/, найдите Gist с описанием 'VLESS Master Configs Map'")
        print("и скопируйте его ID для обновления секрета MASTER_GIST_ID!")
        print("="*50 + "\n")

    # --- 4. ФАЗА СКАНИРОВАНИЯ (DISCOVERY) СУЩЕСТВУЮЩИХ КОНФИГОВ ---
    print("Сканирование существующих Gist-файлов для восстановления связей...")
    page = 1
    discovered_configs = {}
    
    while True:
        resp = requests.get(f"https://api.github.com/gists?per_page=100&page={page}", headers=HEADERS)
        if resp.status_code != 200:
            break
            
        gists = resp.json()
        if not gists:
            break # Достигли конца списка
            
        for gist in gists:
            desc = gist.get('description', '')
            # Ищем гисты, созданные нашим скриптом
            if desc and desc.startswith("Sing-box VLESS Config: "):
                name = desc.replace("Sing-box VLESS Config: ", "").strip()
                # Убеждаемся, что внутри есть нужный JSON файл
                if f"{name}.json" in gist['files']:
                    discovered_configs[name] = {
                        "name": name,
                        "gist_url": gist['html_url'],
                        "raw_url": gist['files'][f'{name}.json']['raw_url'],
                        "gist_id": gist['id']
                    }
        page += 1

    # Восстанавливаем потерянные связи в памяти скрипта
    for name, data in discovered_configs.items():
        if name not in configs_map:
            print(f"Найден потерянный Gist для '{name}'. Связь восстановлена (без дублирования).")
            configs_map[name] = data
    # --------------------------------------------------------------

    # 5. Обрабатываем каждую VLESS ссылку
    for link in vless_links:
        if not isinstance(link, str) or not link.startswith("vless://"):
            continue
            
        parsed = urllib.parse.urlparse(link)
        params = urllib.parse.parse_qs(parsed.query)
        
        uuid = parsed.username
        server_ip = parsed.hostname
        name = urllib.parse.unquote(parsed.fragment)
        
        sni = params.get('sni', [''])[0]
        pbk = params.get('pbk', [''])[0]
        sid = params.get('sid', [''])[0]

        if not name:
            name = f"Unnamed_VLESS_{server_ip}"

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

        # 6. Проверяем существование Gist в нашей карте
        is_existing = False
        if name in configs_map and isinstance(configs_map[name], dict) and 'gist_id' in configs_map[name]:
            is_existing = True

        # 7. Создаем или обновляем конфиги
        if is_existing:
            gist_id = configs_map[name]['gist_id']
            print(f"Обновление Gist для '{name}'...")
            update_resp = requests.patch(f"https://api.github.com/gists/{gist_id}", headers=HEADERS, json=gist_payload)
            
            if update_resp.status_code == 404:
                print(f"Gist для '{name}' был физически удален. Создаем новый...")
                create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=gist_payload)
                create_resp.raise_for_status()
                new_gist = create_resp.json()
                
                configs_map[name] = {
                    "name": name,
                    "gist_url": new_gist['html_url'],
                    "raw_url": new_gist['files'][f'{name}.json']['raw_url'],
                    "gist_id": new_gist['id']
                }
            else:
                update_resp.raise_for_status()
        else:
            print(f"Создание нового Gist для '{name}'...")
            create_resp = requests.post("https://api.github.com/gists", headers=HEADERS, json=gist_payload)
            create_resp.raise_for_status()
            new_gist = create_resp.json()
            
            configs_map[name] = {
                "name": name,
                "gist_url": new_gist['html_url'],
                "raw_url": new_gist['files'][f'{name}.json']['raw_url'],
                "gist_id": new_gist['id']
            }

    # 8. Сохраняем результат
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
