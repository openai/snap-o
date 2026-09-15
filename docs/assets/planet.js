(() => {
  const planet = document.querySelector(".space-planet");
  if (!planet || navigator.connection?.saveData) return;

  const motion = matchMedia("(prefers-reduced-motion: reduce)");
  const canvas = document.createElement("canvas");
  canvas.className = "planet-renderer";
  const scene = planet.closest(".space-scene");
  const sky = document.createElement("canvas");
  sky.className = "space-sky";
  const skyContext = sky.getContext("2d");
  let gl, program, buffer, rotation, evolution, skyPass, aspect;
  let viewportWidth, viewportHeight, planetGeometry;
  let loading = false;
  let ready = false;
  let failed = false;
  let visible = false;
  let suspended = false;
  let frame = 0;
  let previousTime = 0;
  let angle = 0;
  let weatherPhase = 0.25;

  const vertexSource = `
    attribute vec2 position;
    varying vec2 point;
    void main() {
      point = position;
      gl_Position = vec4(position, 0.0, 1.0);
    }
  `;
  const fragmentSource = `
    #extension GL_OES_standard_derivatives : enable
    precision highp float;
    uniform float rotation;
    uniform float evolution;
    uniform bool skyPass;
    uniform float aspect;
    uniform vec2 viewportSize;
    uniform vec4 planetGeometry;
    uniform float planetOpacity;
    varying vec2 point;

    // Continuous 3D noise keeps both the cloud surface and nebula free of seams.
    float hash(vec3 p) {
      p = fract(p * 0.3183099 + vec3(0.17, 0.31, 0.53));
      p *= 17.0;
      return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }
    float noise(vec3 p) {
      vec3 i = floor(p), f = fract(p);
      f = f * f * (3.0 - 2.0 * f);
      return mix(
        mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x),
            mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
        mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
            mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
    }
    float fbm(vec3 p) {
      float sum = 0.0, weight = 0.5;
      for (int i = 0; i < 5; i++) {
        sum += noise(p) * weight;
        p = p * 2.07 + vec3(11.3, 7.1, 3.7);
        weight *= 0.5;
      }
      return sum;
    }
    float cloudNoise(vec3 p) {
      float sum = 0.0, weight = 0.5;
      for (int i = 0; i < 5; i++) {
        // Fade detail smaller than a pixel so fine wisps do not shimmer during rotation.
        float blur = smoothstep(0.35, 1.0, length(fwidth(p)));
        sum += mix(noise(p), 0.5, blur) * weight;
        p = p * 2.07 + vec3(11.3, 7.1, 3.7);
        weight *= 0.5;
      }
      return sum;
    }
    vec3 stormFlow(vec3 p, vec3 center, float radius, float strength) {
      center = normalize(center);
      vec3 offset = p - center;
      float turn = strength * exp(-dot(offset, offset) / (radius * radius))
        * (0.8 + noise(p * 13.0) * 0.35);
      // Rotate on the sphere, with each storm fading smoothly into the surrounding bands.
      return p * cos(turn) + cross(center, p) * sin(turn)
        + center * dot(center, p) * (1.0 - cos(turn));
    }
    vec3 displayColor(vec3 color) {
      color *= 1.15;
      float darkest = min(color.r, min(color.g, color.b));
      color -= darkest < 0.08 ? darkest - 6.25 * darkest * darkest : 0.04;
      return mix(color * 12.92, 1.055 * pow(max(color, 0.0), vec3(1.0 / 2.4)) - 0.055,
                 step(vec3(0.0031308), color));
    }
    vec3 viewDirection() {
      // Use the robot viewer's 32-degree hero camera and its world orientation.
      vec3 forward = normalize(vec3(-9.0, -3.0, -18.0));
      vec3 right = normalize(cross(forward, vec3(0, 1, 0)));
      vec3 up = cross(right, forward);
      return normalize(forward + (right * point.x * aspect + up * point.y) * 0.286745);
    }
    void main() {
      vec3 direction = viewDirection();
      if (skyPass) {
        float band = exp(-pow(dot(direction, normalize(vec3(0.65, 0.72, -0.24))) * 7.0, 2.0));
        float dust = fbm(direction * 9.0 + vec3(7, 2, 13));
        float wisps = pow(max(0.0, dust - 0.23), 2.0) * band;
        vec3 color = vec3(0.001, 0.003, 0.008) + vec3(0.008, 0.025, 0.065) * wisps * 2.5;
        gl_FragColor = vec4(displayColor(color), 1.0);
        return;
      }
      vec2 pixel = (point * 0.5 + 0.5) * viewportSize;
      vec2 local = (pixel - planetGeometry.xy) / planetGeometry.zw;
      float radius = length(local);
      float discriminant = 1.0 - dot(local, local);
      float outerGlow = exp(-max(0.0, radius - 1.0) * 160.0);
      outerGlow *= 1.0 - smoothstep(1.06, 1.12, radius);
      vec3 color = vec3(0.001, 0.20, 0.24) * outerGlow * 0.65;
      float alpha = pow(outerGlow, 1.0 / 2.2);
      float coverage = smoothstep(0.0, max(fwidth(discriminant), 0.000001), discriminant);
      if (discriminant > 0.0) {
        vec3 normal = vec3(local, sqrt(discriminant));
        // Tip the north pole 10 degrees toward the viewer so the cloud belts wrap visibly around it.
        vec3 surface = vec3(mat2(0.9063, 0.4226, -0.4226, 0.9063) * normal.xy, normal.z);
        surface.yz = mat2(0.984808, -0.173648, 0.173648, 0.984808) * surface.yz;
        float turn = rotation * 6.283185;
        surface.xz = mat2(cos(turn), -sin(turn), sin(turn), cos(turn)) * surface.xz;
        float weatherTurn = evolution * 6.283185;
        vec3 weather = stormFlow(surface, vec3(0.20, 0.72, 0.66), 0.105, 3.8 + sin(weatherTurn) * 0.9);
        weather = stormFlow(weather, vec3(-0.55, 0.80, 0.24), 0.065, -3.2 + (sin(weatherTurn + 0.8) - sin(0.8)) * 0.6);
        // Broad currents carry long wisps between the localized storms.
        float drift = cloudNoise(weather * 2.2 + vec3(7, 13, 2));
        float curl = cloudNoise(weather * 3.2 + drift * 0.7 + vec3(19, 3, 11));
        vec3 flow = weather * vec3(3.0, 36.0, 3.0) + vec3(curl * 0.45, drift * 2.4 + curl, drift * 0.45);
        // Small, periodic offsets evolve the wisps without a jump when the weather cycle repeats.
        flow += vec3(sin(weatherTurn) * 0.65, sin(weatherTurn + weather.y * 4.0) - sin(weather.y * 4.0),
                     (cos(weatherTurn) - 1.0) * 0.65) * vec3(1.0, 0.5, 1.0);
        float clouds = cloudNoise(flow);
        // Add fine detail across the trails without chopping their length into short wisps.
        float detail = cloudNoise(flow * vec3(0.85, 2.8, 0.85) + clouds * 0.35 + vec3(3, 7, 17));
        float belt = 0.5 + 0.5 * sin(weather.y * 17.0 + drift * 1.8 + curl * 0.6);
        float vapor = clamp((clouds - 0.25) * 1.8 + (detail - 0.5) * 0.45, 0.0, 1.0);
        vec3 surfaceColor = mix(vec3(0.003, 0.025, 0.050), vec3(0.008, 0.075, 0.115), belt * 0.65 + clouds * 0.35);
        surfaceColor = mix(surfaceColor, vec3(0.16, 0.27, 0.25), min(1.0, vapor * vapor * 1.5 * (0.2 + belt * 0.8)));
        float daylight = max(0.0, dot(normal, normalize(vec3(0.5, 0.75, 0.65))));
        float polarLight = smoothstep(0.45, 1.0, surface.y) * daylight;
        surfaceColor *= 0.10 + daylight * 1.35 + polarLight * 0.65;
        surfaceColor += vec3(0.012, 0.032, 0.038) * polarLight;
        float limb = 1.0 - normal.z;
        surfaceColor += vec3(0.015, 0.55, 0.65) * pow(limb, 7.0) * (0.3 + daylight * 0.7);
        surfaceColor += vec3(0.04, 0.80, 0.90) * exp(-normal.z * 20.0) * (0.42 + daylight * 0.98);
        color = mix(color, surfaceColor, coverage);
        alpha = mix(alpha, 1.0, coverage);
      }
      // Match the artwork's 125-degree mask and responsive opacity without exposing the sky through the globe.
      vec2 artwork = vec2(local.x * 0.47, -local.y * 0.46);
      float gradient = 0.5 + dot(artwork, vec2(0.819152, 0.573576)) / 1.392728;
      float fade = clamp((gradient - 0.06) / 0.39, 0.0, 1.0) * planetOpacity;
      vec3 backdrop = vec3(4.0, 12.0, 22.0) / 255.0;
      vec3 muted = mix(backdrop * alpha, displayColor(color), fade);
      gl_FragColor = vec4(muted, alpha);
    }
  `;

  function stop() {
    cancelAnimationFrame(frame);
    frame = 0;
    previousTime = 0;
  }

  function fallback() {
    failed = true;
    ready = false;
    stop();
    planet.classList.remove("is-ready");
    scene?.classList.remove("has-sky");
    canvas.remove();
    sky.remove();
    if (gl) {
      gl.deleteBuffer(buffer);
      gl.deleteProgram(program);
    }
  }

  function planetCovers(x, y) {
    return Math.hypot((x - planetGeometry[0]) / planetGeometry[2],
      (viewportHeight - y - planetGeometry[1]) / planetGeometry[3]) < 1;
  }

  function renderSky() {
    if (!scene || !skyContext) return;
    const density = Math.min(devicePixelRatio || 1, 1.5, 1536 / viewportWidth);
    sky.width = Math.round(viewportWidth * density);
    sky.height = Math.round(viewportHeight * density);
    // Cache the nebula once per resize; only the planet needs animation frames.
    canvas.width = Math.max(1, Math.round(sky.width / 2));
    canvas.height = Math.max(1, Math.round(sky.height / 2));
    gl.disable(gl.SCISSOR_TEST);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform1i(skyPass, 1);
    gl.uniform1f(aspect, viewportWidth / viewportHeight);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    skyContext.drawImage(canvas, 0, 0, sky.width, sky.height);
    skyContext.scale(density, density);

    // Use the viewer's seeded star sizes and brightness; the planet hides distant stars.
    let seed = 4317;
    const random = () => { seed = (1664525 * seed + 1013904223) >>> 0; return seed / 4294967296; };
    for (let i = 0; i < Math.ceil(viewportWidth * viewportHeight / 2400); i++) {
      const x = random() * viewportWidth, y = random() * viewportHeight;
      const radius = 0.5 + random() ** 3 * 0.9;
      const brightness = 0.35 + random() ** 3 * 0.65;
      if (planetCovers(x, y)) continue;
      const glow = skyContext.createRadialGradient(x, y, 0, x, y, radius);
      glow.addColorStop(0, `rgba(184, 214, 255, ${brightness})`);
      glow.addColorStop(1, "rgba(184, 214, 255, 0)");
      skyContext.fillStyle = glow;
      skyContext.fillRect(x - radius, y - radius, radius * 2, radius * 2);
    }
    gl.uniform1i(skyPass, 0);
    scene.prepend(sky);
    scene.classList.add("has-sky");
  }

  function shader(type, source) {
    const value = gl.createShader(type);
    gl.shaderSource(value, source);
    gl.compileShader(value);
    if (!gl.getShaderParameter(value, gl.COMPILE_STATUS)) {
      gl.deleteShader(value);
      throw new Error("Planet shader unavailable");
    }
    gl.attachShader(program, value);
    gl.deleteShader(value);
  }

  function resize() {
    if (!ready) return;
    const viewport = scene.getBoundingClientRect();
    const bounds = planet.getBoundingClientRect();
    viewportWidth = viewport.width;
    viewportHeight = viewport.height;
    // The WebP has a small margin and a slightly flattened globe inside its square.
    planetGeometry = [bounds.left - viewport.left + bounds.width * 0.5,
      viewport.bottom - bounds.top - bounds.height * 0.5,
      bounds.width * 0.47, bounds.height * 0.46];
    gl.uniform2f(gl.getUniformLocation(program, "viewportSize"), viewportWidth, viewportHeight);
    gl.uniform4fv(gl.getUniformLocation(program, "planetGeometry"), planetGeometry);
    gl.uniform1f(gl.getUniformLocation(program, "planetOpacity"), Math.min(1, Number(getComputedStyle(planet).opacity) * 1.3));
    renderSky();
    // Keep the limb sharp while limiting the buffer and skipping offscreen shading.
    const density = Math.min(devicePixelRatio || 1, 1.5, 2560 / viewportWidth, 1536 / viewportHeight);
    canvas.width = Math.max(1, Math.round(viewportWidth * density));
    canvas.height = Math.max(1, Math.round(viewportHeight * density));
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform1f(aspect, viewportWidth / viewportHeight);
    gl.enable(gl.SCISSOR_TEST);
    const [centerX, centerY, radiusX, radiusY] = planetGeometry;
    const left = Math.max(0, centerX - radiusX * 1.12);
    const bottom = Math.max(0, centerY - radiusY * 1.12);
    const right = Math.min(viewportWidth, centerX + radiusX * 1.12);
    const top = Math.min(viewportHeight, centerY + radiusY * 1.12);
    visible = right > left && top > bottom;
    gl.scissor(Math.floor(left * density), Math.floor(bottom * density),
      Math.max(0, Math.ceil((right - left) * density)), Math.max(0, Math.ceil((top - bottom) * density)));
    update();
  }

  function draw(time) {
    frame = requestAnimationFrame(draw);
    const elapsed = previousTime ? time - previousTime : 0;
    if (previousTime && elapsed < 1000 / 30) return;
    previousTime = time;
    angle = (angle + Math.min(elapsed, 100) / 240000) % 1;
    weatherPhase = (weatherPhase + Math.min(elapsed, 100) / 240000) % 1;
    gl.uniform1f(rotation, angle);
    gl.uniform1f(evolution, weatherPhase);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    planet.classList.add("is-ready");
  }

  function initialize() {
    loading = true;
    try {
      gl = canvas.getContext("webgl", {
        alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false,
        powerPreference: "low-power",
      });
      if (!gl) throw new Error("WebGL unavailable");
      if (!gl.getExtension("OES_standard_derivatives")) throw new Error("Planet shading unavailable");
      program = gl.createProgram();
      shader(gl.VERTEX_SHADER, vertexSource);
      shader(gl.FRAGMENT_SHADER, fragmentSource);
      gl.linkProgram(program);
      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error("Planet program unavailable");
      gl.useProgram(program);
      buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const position = gl.getAttribLocation(program, "position");
      gl.enableVertexAttribArray(position);
      gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
      rotation = gl.getUniformLocation(program, "rotation");
      evolution = gl.getUniformLocation(program, "evolution");
      skyPass = gl.getUniformLocation(program, "skyPass");
      aspect = gl.getUniformLocation(program, "aspect");
      if (gl.isContextLost() || gl.getError() !== gl.NO_ERROR) throw new Error("Planet graphics unavailable");
      planet.after(canvas);
      ready = true;
      resize();
    } catch {
      fallback();
    }
  }

  function update() {
    stop();
    if (motion.matches) planet.classList.remove("is-ready");
    if (failed || motion.matches || document.hidden || suspended) return;
    if (!loading) initialize();
    else if (ready && visible) frame = requestAnimationFrame(draw);
  }

  canvas.addEventListener("webglcontextlost", fallback);
  motion.addEventListener("change", update);
  document.addEventListener("visibilitychange", update);
  window.addEventListener("resize", resize);
  window.addEventListener("pagehide", () => { suspended = true; stop(); });
  window.addEventListener("pageshow", () => { suspended = false; update(); });
  // Let the page paint before compiling shaders.
  requestAnimationFrame(() => setTimeout(update, 0));
})();
