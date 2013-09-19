/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "PLCrashAsyncThread.h"
#import "PLCrashAsync.h"

#import <signal.h>
#import <stdlib.h>
#import <assert.h>

#ifdef __arm__

#define RETGEN(name, type, ts) {\
    return (ts->arm_state. type . __ ## name); \
}

#define SETGEN(name, type, ts, regnum, value) {\
    ts->valid_regs |= 1<<regnum; \
    (ts->arm_state. type . __ ## name) = value; \
    break; \
}

/* Mapping of DWARF register numbers to PLCrashReporter register numbers. */
struct dwarf_register_table {
    /** Standard register number. */
    plcrash_regnum_t regnum;
    
    /** DWARF register number. */
    uint64_t dwarf_value;
};


/*
 * ARM GP registers defined as callee-preserved, as per Apple's iOS ARM
 * Function Call Guide
 */
static const plcrash_regnum_t arm_nonvolatile_registers[] = {
    PLCRASH_ARM_R4,
    PLCRASH_ARM_R5,
    PLCRASH_ARM_R6,
    PLCRASH_ARM_R7,
    PLCRASH_ARM_R8,
    PLCRASH_ARM_R10,
    PLCRASH_ARM_R11,
};

/**
 * DWARF register mappings as defined in ARM's "DWARF for the ARM Architecture", ARM IHI 0040B,
 * issued November 30th, 2012.
 *
 * Note that not all registers have DWARF register numbers allocated, eg, the ARM standard states
 * in Section 3.1:
 *
 *   The CPSR, VFP and FPA control registers are not allocated a numbering above. It is
 *   considered unlikely that these will be needed for producing a stack back-trace in a
 *   debugger.
 */
static const struct dwarf_register_table arm_dwarf_table [] = {
    { PLCRASH_ARM_R0, 0 },
    { PLCRASH_ARM_R1, 1 },
    { PLCRASH_ARM_R2, 2 },
    { PLCRASH_ARM_R3, 3 },
    { PLCRASH_ARM_R4, 4 },
    { PLCRASH_ARM_R5, 5 },
    { PLCRASH_ARM_R6, 6 },
    { PLCRASH_ARM_R7, 7 },
    { PLCRASH_ARM_R8, 8 },
    { PLCRASH_ARM_R9, 9 },
    { PLCRASH_ARM_R10, 10 },
    { PLCRASH_ARM_R11, 11 },
    { PLCRASH_ARM_R12, 12 },
    { PLCRASH_ARM_SP, 13 },
    { PLCRASH_ARM_LR, 14 },
    { PLCRASH_ARM_PC, 15 }
};



// PLCrashAsyncThread API
plcrash_greg_t plcrash_async_thread_state_get_reg (const plcrash_async_thread_state_t *ts, plcrash_regnum_t regnum) {
    switch (regnum) {
        case PLCRASH_ARM_R0:
            RETGEN(r[0], thread, ts);
            
        case PLCRASH_ARM_R1:
            RETGEN(r[1], thread, ts);
            
        case PLCRASH_ARM_R2:
            RETGEN(r[2], thread, ts);
            
        case PLCRASH_ARM_R3:
            RETGEN(r[3], thread, ts);
            
        case PLCRASH_ARM_R4:
            RETGEN(r[4], thread, ts);
            
        case PLCRASH_ARM_R5:
            RETGEN(r[5], thread, ts);
            
        case PLCRASH_ARM_R6:
            RETGEN(r[6], thread, ts);
            
        case PLCRASH_ARM_R7:
            RETGEN(r[7], thread, ts);
            
        case PLCRASH_ARM_R8:
            RETGEN(r[8], thread, ts);
            
        case PLCRASH_ARM_R9:
            RETGEN(r[9], thread, ts);
            
        case PLCRASH_ARM_R10:
            RETGEN(r[10], thread, ts);
            
        case PLCRASH_ARM_R11:
            RETGEN(r[11], thread, ts);
            
        case PLCRASH_ARM_R12:
            RETGEN(r[12], thread, ts);
            
        case PLCRASH_ARM_SP:
            RETGEN(sp, thread, ts);
            
        case PLCRASH_ARM_LR:
            RETGEN(lr, thread, ts);
            
        case PLCRASH_ARM_PC:
            RETGEN(pc, thread, ts);
            
        case PLCRASH_ARM_CPSR:
            RETGEN(cpsr, thread, ts);
            
        default:
            __builtin_trap();
    }

    /* Should not be reachable */
    return 0;
}

// PLCrashAsyncThread API
void plcrash_async_thread_state_set_reg (plcrash_async_thread_state_t *thread_state, plcrash_regnum_t regnum, plcrash_greg_t reg) {
    plcrash_async_thread_state_t *ts = thread_state;

    switch (regnum) {
        case PLCRASH_ARM_R0:
            SETGEN(r[0], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R1:
            SETGEN(r[1], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R2:
            SETGEN(r[2], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R3:
            SETGEN(r[3], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R4:
            SETGEN(r[4], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R5:
            SETGEN(r[5], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R6:
            SETGEN(r[6], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R7:
            SETGEN(r[7], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R8:
            SETGEN(r[8], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R9:
            SETGEN(r[9], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R10:
            SETGEN(r[10], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R11:
            SETGEN(r[11], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_R12:
            SETGEN(r[12], thread, ts, regnum, reg);
            
        case PLCRASH_ARM_SP:
            SETGEN(sp, thread, ts, regnum, reg);
            
        case PLCRASH_ARM_LR:
            SETGEN(lr, thread, ts, regnum, reg);
            
        case PLCRASH_ARM_PC:
            SETGEN(pc, thread, ts, regnum, reg);
            
        case PLCRASH_ARM_CPSR:
            SETGEN(cpsr, thread, ts, regnum, reg);
            
        default:
            // Unsupported register
            __builtin_trap();
    }
}

// PLCrashAsyncThread API
size_t plcrash_async_thread_state_get_reg_count (const plcrash_async_thread_state_t *thread_state) {
    /* Last is an index value, so increment to get the count */
    return PLCRASH_ARM_LAST_REG+1;
}

// PLCrashAsyncThread API
char const *plcrash_async_thread_state_get_reg_name (const plcrash_async_thread_state_t *thread_state, plcrash_regnum_t regnum) {
    switch (regnum) {
        case PLCRASH_ARM_R0:
            return "r0";
        case PLCRASH_ARM_R1:
            return "r1";
        case PLCRASH_ARM_R2:
            return "r2";
        case PLCRASH_ARM_R3:
            return "r3";
        case PLCRASH_ARM_R4:
            return "r4";
        case PLCRASH_ARM_R5:
            return "r5";
        case PLCRASH_ARM_R6:
            return "r6";
        case PLCRASH_ARM_R7:
            return "r7";
        case PLCRASH_ARM_R8:
            return "r8";
        case PLCRASH_ARM_R9:
            return "r9";
        case PLCRASH_ARM_R10:
            return "r10";
        case PLCRASH_ARM_R11:
            return "r11";
        case PLCRASH_ARM_R12:
            return "r12";
            
        case PLCRASH_ARM_SP:
            return "sp";
            
        case PLCRASH_ARM_LR:
            return "lr";
            
        case PLCRASH_ARM_PC:
            return "pc";
            
        case PLCRASH_ARM_CPSR:
            return "cpsr";
            
        default:
            // Unsupported register
            break;
    }
    
    /* Unsupported register is an implementation error (checked in unit tests) */
    PLCF_DEBUG("Missing register name for register id: %d", regnum);
    abort();
}

// PLCrashAsyncThread API
void plcrash_async_thread_state_clear_volatile_regs (plcrash_async_thread_state_t *thread_state) {
    size_t table_count = sizeof(arm_nonvolatile_registers) / sizeof(arm_nonvolatile_registers[0]);;
    
    size_t reg_count = plcrash_async_thread_state_get_reg_count(thread_state);
    for (size_t reg = 0; reg < reg_count; reg++) {
        /* Skip unset registers */
        if (!plcrash_async_thread_state_has_reg(thread_state, reg))
            continue;
        
        /* Check for the register in the preservation table */
        bool preserved = false;
        for (size_t i = 0; i < table_count; i++) {
            if (arm_nonvolatile_registers[i] == reg) {
                preserved = true;
                break;
            }
        }
        
        /* If not preserved, clear */
        if (!preserved)
            plcrash_async_thread_state_clear_reg(thread_state, reg);
    }
}

// PLCrashAsyncThread API
bool plcrash_async_thread_state_map_reg_to_dwarf (plcrash_async_thread_state_t *thread_state, plcrash_regnum_t regnum, uint64_t *dwarf_reg) {
    for (size_t i = 0; i < sizeof(arm_dwarf_table) / sizeof(arm_dwarf_table[0]); i++) {
        if (arm_dwarf_table[i].regnum == regnum) {
            *dwarf_reg = arm_dwarf_table[i].dwarf_value;
            return true;
        }
    }
    
    /* Unknown DWARF register.  */
    return false;
}

// PLCrashAsyncThread API
bool plcrash_async_thread_state_map_dwarf_to_reg (const plcrash_async_thread_state_t *thread_state, uint64_t dwarf_reg, plcrash_regnum_t *regnum) {
    for (size_t i = 0; i < sizeof(arm_dwarf_table) / sizeof(arm_dwarf_table[0]); i++) {
        if (arm_dwarf_table[i].dwarf_value == dwarf_reg) {
            *regnum = arm_dwarf_table[i].regnum;
            return true;
        }
    }
    
    /* Unknown DWARF register.  */
    return false;
}

#endif /* __arm__ */
