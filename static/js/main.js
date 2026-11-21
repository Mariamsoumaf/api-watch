// Open a dialog: <button data-open="dialog-id">
document.querySelectorAll('[data-open]').forEach(btn => {
  btn.addEventListener('click', () => document.getElementById(btn.dataset.open).showModal());
});

// Close the dialog that contains this button
document.querySelectorAll('[data-close]').forEach(btn => {
  btn.addEventListener('click', () => btn.closest('dialog').close());
});

// Edit buttons: fill the edit form with the monitor's data, then open it
document.querySelectorAll('[data-edit]').forEach(btn => {
  btn.addEventListener('click', () => {
    document.getElementById('edit-form').action = btn.dataset.action;
    document.getElementById('edit-name').value = btn.dataset.name;
    document.getElementById('edit-url').value = btn.dataset.url;
    document.getElementById('edit-interval').value = btn.dataset.interval;
    document.getElementById('edit-dialog').showModal();
  });
});

// Hide flash messages after 5 seconds
setTimeout(() => {
  document.querySelectorAll('.flash').forEach(el => {
    el.style.transition = 'opacity .4s';
    el.style.opacity = '0';
    setTimeout(() => el.remove(), 400);
  });
}, 5000);
