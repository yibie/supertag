import { useState, useEffect } from 'react'

/**
 * Returns true while the Shift key is held down.
 * Used to switch nodes between drag-to-move and drag-to-connect modes.
 */
export function useShiftKey(): boolean {
  const [shiftHeld, setShiftHeld] = useState(false)

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Shift') setShiftHeld(true)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      if (e.key === 'Shift') setShiftHeld(false)
    }
    // Also clear on window blur so Shift doesn't get stuck
    const onBlur = () => setShiftHeld(false)

    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
      window.removeEventListener('blur', onBlur)
    }
  }, [])

  return shiftHeld
}
