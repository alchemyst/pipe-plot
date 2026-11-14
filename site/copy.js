// Progressive enhancement: examples remain selectable without JavaScript.
for (const button of document.querySelectorAll('.copy')) {
  button.hidden = false;
  button.addEventListener('click', async () => {
    const code = button.closest('.command').querySelector('code');
    const status = document.getElementById('copy-status');
    try {
      await navigator.clipboard.writeText(code.textContent);
      status.textContent = 'Command copied.';
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 2000);
    } catch {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = 'Command selected. Press Command-C or Ctrl-C to copy.';
      button.textContent = 'Selected';
      setTimeout(() => { button.textContent = 'Copy'; }, 2000);
    }
  });
}
