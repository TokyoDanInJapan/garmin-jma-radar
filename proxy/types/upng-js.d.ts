// upng-js ships no type declarations. We use a tiny surface (decode, toRGBA8,
// encode); declare just enough for the type-checker rather than pulling `any`.
declare module "upng-js" {
  interface UPNGImage {
    width: number;
    height: number;
    depth: number;
    ctype: number;
    data: Uint8Array;
  }
  const UPNG: {
    decode(buffer: ArrayBuffer | Uint8Array): UPNGImage;
    toRGBA8(img: UPNGImage): ArrayBuffer[];
    encode(
      bufs: ArrayBuffer[],
      w: number,
      h: number,
      cnum: number,
      dels?: number[]
    ): ArrayBuffer;
  };
  export default UPNG;
}
