var wasmExports = null;

WebAssembly.instantiateStreaming(fetch("pgen-bridge.wasm")).then(
    (result) => {
        wasmExports = result.instance.exports;
    },
);

function backendParse(input) {
    if (!/^[\x00-\x7F]*$/.test(input))
        return "ASCII only please";
    if (wasmExports == null)
        return "Loading... Try again later";
    if (input == "")
        return "Type something...";
    const {
        memory, pgenParse, newMessagePtr,
        releaseMessage, newBuffer, freeBuffer,
        messagePtr, messageLen, invalidPtr,
    } = wasmExports;
    console.log(wasmExports);
    const nullPtr = invalidPtr();
    const inLen = input.length;
    const inBuffer = newBuffer(inLen);
    if (inBuffer == nullPtr)
        return "Out of memory";
    const msg = newMessagePtr();
    if (msg == nullPtr) {
        freeBuffer(inBuffer, inLen);
        return "Out of memory";
    }
    new TextEncoder().encodeInto(input, new Uint8Array(memory.buffer, inBuffer, inLen));
    pgenParse(inBuffer, inLen, msg);
    freeBuffer(inBuffer, inLen);
    const output = new TextDecoder().decode(new Uint8Array(
        memory.buffer, messagePtr(msg), messageLen(msg)
    ));
    releaseMessage(msg);
    return output;
}

document.addEventListener('DOMContentLoaded', () => {
    const inputSource = document.getElementById("input-source");
    const outputMessage = document.getElementById("output-message");
    let debounceTimer = null;
    function goParse() {
        outputMessage.textContent = backendParse(inputSource.value);
    }
    function onInputChanged() {
        if (debounceTimer != null)
            clearTimeout(debounceTimer);
        debounceTimer = setTimeout(goParse, 500);
    }
    inputSource.addEventListener('input', onInputChanged);
});
