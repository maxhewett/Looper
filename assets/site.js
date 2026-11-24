const themeKey = "looper-theme";
const themes = ["auto", "light", "dark"];
let theme = "auto";
try {
  const saved = localStorage.getItem(themeKey);
  if (themes.includes(saved)) theme = saved;
} catch {}
document.documentElement.dataset.theme = theme;

document.addEventListener("DOMContentLoaded", () => {
  const picker = document.querySelector("#theme");
  picker.value = theme;
  picker.hidden = false;
  picker.addEventListener("change", () => {
    document.documentElement.dataset.theme = picker.value;
    try { localStorage.setItem(themeKey, picker.value); } catch {}
  });

  const play = document.querySelector("#play-menu");
  if (play) {
    play.hidden = false;
    play.addEventListener("click", () => {
      const active = document.querySelector(".menu-frame").classList.toggle("playing");
      play.textContent = active ? "Pause animation" : "Play animation";
    });
  }
  const track = document.querySelector(".track");
  if (!track) return;
  const slides = [...track.querySelectorAll("figure")];
  const controls = document.querySelector(".carousel-nav");
  const buttons = [...controls.querySelectorAll("button")];
  const position = controls.querySelector("span");
  controls.hidden = false;
  let active = 0;

  function updatePosition() {
    const start = track.getBoundingClientRect().left;
    const distances = slides.map(slide => Math.abs(slide.getBoundingClientRect().left - start));
    active = distances.indexOf(Math.min(...distances));
    const label = slides[active].dataset.label + " · " + (active + 1) + " of " + slides.length;
    if (position.textContent !== label) position.textContent = label;
    buttons[0].disabled = active === 0;
    buttons[1].disabled = active === slides.length - 1;
  }
  buttons.forEach(button => button.addEventListener("click", () => {
    const target = slides[active + Number(button.dataset.step)];
    if (target) track.scrollTo({left: target.offsetLeft - slides[0].offsetLeft});
  }));
  track.addEventListener("scroll", updatePosition, {passive: true});
  new ResizeObserver(updatePosition).observe(track);
  updatePosition();

  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("entered");
        observer.unobserve(entry.target);
      }
    }
  });
  document.querySelectorAll(".gallery h2, .menu-demo, .guides").forEach(section => observer.observe(section));
});
