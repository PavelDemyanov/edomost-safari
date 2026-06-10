function send(msg) {
    try { webkit.messageHandlers.controller.postMessage(msg); } catch (e) {}
}

function sendResize() {
    requestAnimationFrame(function () {
        send("resize:" + (document.body.scrollHeight + 2));
    });
}

var NOTE_DEFAULT = "Нужен установленный плагин ЭЦП — тот же, что для Chrome (КриптоПро и локальный плагин на 127.0.0.1). Приложение неофициальное, не связано с сервисами ЭДО.";
var NOTE_WARN = "Плагин подписи не найден. Проверьте, что подпись работает в Chrome (нужны КриптоПро и плагин «Моё Дело»).";

var busyTimer = null;

// Вызывается из ViewController (Swift) после автоматической проверки.
// service: "on" | "off" | "noplugin" — состояние фонового режима плагина.
window.updateStatus = function (extEnabled, pluginOk, service) {
    document.body.dataset.state = extEnabled ? "on" : "off";
    if (service) { document.body.dataset.service = service; }
    clearTimeout(busyTimer);

    var note = document.getElementById("note");
    var noteText = document.getElementById("note-text");
    if (note && noteText) {
        if (pluginOk) {
            note.classList.remove("warn");
            noteText.textContent = NOTE_DEFAULT;
        } else {
            note.classList.add("warn");
            noteText.textContent = NOTE_WARN;
        }
    }

    // Подгоняем высоту окна под контент состояния (без скролла и без зазора).
    sendResize();
};

// Пока Swift включает/выключает службу, показываем «Применяю…»;
// если ответ потерялся — через 20 секунд перепроверяем статус сами.
function setBusy() {
    document.body.dataset.service = "busy";
    sendResize();
    clearTimeout(busyTimer);
    busyTimer = setTimeout(function () { send("check-status"); }, 20000);
}

document.addEventListener("click", function (e) {
    var openPrefs = e.target.closest(".btn-open-prefs");
    if (openPrefs) { send("open-preferences"); return; }
    var openMd = e.target.closest(".btn-open-moedelo");
    if (openMd) { send("open-moedelo"); return; }
    var svcOn = e.target.closest(".btn-svc-on");
    if (svcOn) { setBusy(); send("service-on"); return; }
    var svcOff = e.target.closest(".btn-svc-off");
    if (svcOff) { setBusy(); send("service-off"); return; }
});
