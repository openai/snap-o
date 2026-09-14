const robot = document.querySelector(".robot-flight");
const robotImage = robot.querySelector(".space-robot");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let flight = null;

robot.addEventListener("click", () => {
  if (flight) return;

  // Freeze the idle pose so it cannot shift the rotation's center mid-flip.
  robotImage.style.animationPlayState = "paused";
  const idleTransform = getComputedStyle(robotImage).transform;
  const pose = idleTransform === "none" ? "" : idleTransform;
  const radius = Math.min(52, robotImage.clientWidth * 0.22) * 5.2;
  // Keep the guide's loop inside the viewport by flying left and down from its corner.
  const startAngle = robot.classList.contains("guide-robot") ? -Math.PI / 4 : 3 * Math.PI / 4;
  const keyframes = reducedMotion.matches
    ? [1, 1.04, 1].map(scale => ({ transform: `${pose} scale(${scale})` }))
    : Array.from({ length: 61 }, (_, frame) => {
        const progress = frame / 60;
        const angle = startAngle + progress * 2 * Math.PI;
        const x = radius * (Math.cos(angle) - Math.cos(startAngle));
        const y = radius * (Math.sin(angle) - Math.sin(startAngle));
        return {
          transform: `translate(${x}px, ${y}px) ${pose} rotate(${progress * 360}deg)`,
        };
      });

  flight = robotImage.animate(keyframes, {
    duration: reducedMotion.matches ? 320 : 900,
    easing: reducedMotion.matches ? "ease-in-out" : "cubic-bezier(0.42, 0, 0.18, 1)",
  });
  flight.finished.catch(() => {}).finally(() => {
    robotImage.style.animationPlayState = "";
    flight = null;
  });
});

reducedMotion.addEventListener("change", () => {
  if (reducedMotion.matches) flight?.cancel();
});
