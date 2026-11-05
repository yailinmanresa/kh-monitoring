import time
import pyautogui
import pyperclip

def auto_type_clipboard():
    text = pyperclip.paste()
    if not text:
        print("Klembord is leeg!")
        return

    print("==================================================")
    print("KLIK BINNEN 3 SECONDEN IN JE TIGHTVNC TERMINAL...")
    print("==================================================")

    for i in range(3, 0, -1):
        print(f"{i}...")
        time.sleep(1)

    print("\nBezig met typen...")

    # Type regel voor regel met een korte pauze tussen de regels
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line:
            # write typt de karakters letter voor letter (interval in seconden)
            pyautogui.write(line, interval=0.015)

        # Als er meerdere regels zijn, druk op enter na elke regel
        if index < len(lines) - 1 or text.endswith('\n'):
            pyautogui.press('enter')
            time.sleep(0.1)  # Korte pauze zodat de shell de regel kan verwerken

    print("\nKlaar met typen!")

if __name__ == "__main__":
    auto_type_clipboard()
