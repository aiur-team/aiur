(() => {
  window.AiurVoiceWaveform = {
    pushWaveform(samples) {
      this.waveform.push(samples);
      this.drawWaveform();
    },

    resetWaveform() {
      this.waveform.reset();
      this.drawWaveform();
    },

    drawWaveform() {
      const context = this.canvas?.getContext("2d");
      const columns = this.waveform?.columns;
      if (!this.canvas || !context || !columns) return;
      const style = window.getComputedStyle(this.hook.el);
      const middle = this.canvas.height / 2;
      context.clearRect(0, 0, this.canvas.width, this.canvas.height);
      context.strokeStyle = style.getPropertyValue("--line").trim() || "#4b5563";
      context.beginPath();
      context.moveTo(0, middle + 0.5);
      context.lineTo(this.canvas.width, middle + 0.5);
      context.stroke();
      context.strokeStyle = style.getPropertyValue("--accent").trim() || "#3ba55d";
      context.lineWidth = Math.max(1, this.canvas.width / columns.length * 0.7);
      const scale = this.canvas.height * 0.43;
      columns.forEach((column, index) => {
        const x = (index + 0.5) * this.canvas.width / columns.length;
        context.beginPath();
        context.moveTo(x, middle - column.max * scale);
        context.lineTo(x, middle - column.min * scale);
        context.stroke();
      });
    }
  };
})();
